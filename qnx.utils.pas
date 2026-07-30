unit QNX.Utils;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, qnx6, qnx6.types;

type
  TDirEntryInfo = record
    Name: string;
    size: qword;
    uid: dword;
    gid: dword;
    ftime: dword;
    mtime: dword;
    atime: dword;
    ctime: dword;
    mode: word;
    inodeIdx: integer;
  end;

  TDirEntryInfoArray = array of TDirEntryInfo;

function Path2QNX(const s: string): string; inline;
function ExtractPOSIXFilePath(const APath: string): string;
function EnsurePOSIXTrailingSlash(const APath: string): string;

function qnx6_MkDir(FS: TQNX6Fs; const aName: string; const Recursive: boolean): boolean;
function qnx6_RmDir(FS: TQNX6Fs; const aName: string; const Recursive: boolean): boolean;
function qnx6_Rm(FS: TQNX6Fs; const aName: string): boolean;

function qnx6_readFile(FS: TQNX6Fs; const aName: string; Data: TMemoryStream): integer;
function qnx6_writeFile(FS: TQNX6Fs; const aName: string; Data: TMemoryStream): integer;

function qnx6_readDir(FS: TQNX6Fs; const aPath: string; out EntriesList: TDirEntryInfoArray): integer;

implementation

{$POINTERMATH ON}

function Path2QNX(const s: string): string; inline;
begin
  if DirectorySeparator <> '/' then
    Result := ReplaceStr(s, '\', '/')
  else
    Result := s;
end;

function ExtractPOSIXFilePath(const APath: string): string;
var
  i: integer;
begin
  i := LastDelimiter('/', APath);
  if i > 0 then
    Result := Copy(APath, 1, i)
  else
    Result := '';
end;

function EnsurePOSIXTrailingSlash(const APath: string): string;
begin
  Result := APath;
  if (Result <> '') and (Result[Length(Result)] <> '/') then
    Result := Result + '/';
end;

function qnx6_MkDir(FS: TQNX6Fs; const aName: string; const Recursive: boolean): boolean;
var
  Path: rawbytestring;
  SubPath: rawbytestring;
  i, res, len: integer;
begin
  Result := False;
  if FS = nil then Exit;

  Path := Path2QNX(aName);

  while (Length(Path) > 1) and (Path[Length(Path)] = '/') do
    Delete(Path, Length(Path), 1);

  len := Length(Path);
  if len = 0 then Exit;

  if Recursive then
  begin
    for i := 1 to len do
    begin
      if (Path[i] = '/') or (i = len) then
      begin
        if i = len then
          SubPath := Path
        else
          SubPath := Copy(Path, 1, i - 1);

        if (SubPath <> '') and (SubPath <> '/') then
        begin
          res := FS.MkDir(pansichar(SubPath), &777);
          Result := (res >= 0) or (res = -ESysEEXIST);
          if not Result then Exit;
        end;
      end;
    end;
  end
  else
  begin
    res := FS.MkDir(pansichar(Path), &777);
    Result := (res = 0) or (res = -ESysEEXIST);
  end;
end;

function qnx6_RmDir(FS: TQNX6Fs; const aName: string; const Recursive: boolean): boolean;
var
  Path: rawbytestring;
begin
  Result := False;
  if FS = nil then Exit;

  Path := Path2QNX(aName);
  if Recursive then
    Result := FS.RemoveAllIterative(PChar(Path)) = 0
  else
    Result := FS.removeFileDir(PChar(Path), True) = 0;
end;

function qnx6_Rm(FS: TQNX6Fs; const aName: string): boolean;
var
  Path: rawbytestring;
begin
  Result := False;
  if FS = nil then Exit;

  Path := Path2QNX(aName);
  Result := FS.removeFileDir(PChar(Path), False) = 0;
end;

function qnx6_readFile(FS: TQNX6Fs; const aName: string; Data: TMemoryStream): integer;
var
  idx, i, blockCount: integer;
  Blocks: TBlocksList;
  fsize: QWord;
  buff: array of byte;
  pDest: pbyte;
begin
  Result := -1;
  if FS = nil then Exit;

  idx := FS.GetInodeByPath(PChar(aName));
  if idx < 1 then Exit;

  fsize := FS.Inodes[idx].size;
  Data.SetSize(fsize);
  if fsize = 0 then
  begin
    Result := 0;
    Exit;
  end;

  FS.InodeMgr.LoadInodeBlocks(idx, Blocks);

  blockCount := fsize div FS.BlockSize;
  if (fsize and (FS.BlockSize - 1)) <> 0 then
    Inc(blockCount);

  if Blocks.level[0].Count < blockCount then Exit;

  SetLength(buff, QWord(blockCount) * FS.BlockSize);

  for i := 0 to blockCount - 1 do
  begin
    FS.ReadBlock(Blocks.level[0].Data[i], @buff[QWord(i) * FS.BlockSize]);
  end;

  pDest := Data.Memory;
  if (pDest <> nil) and (fsize > 0) then
    Move(buff[0], pDest^, fsize);

  Result := 0;
end;

function qnx6_writeFile(FS: TQNX6Fs; const aName: string; Data: TMemoryStream): integer;
var
  idx, i, blockCount: integer;
  Blocks: TBlocksList;
  fsize: QWord;
  buff: array of byte;
  pSource: pbyte;
begin
  Result := -1;
  if FS = nil then Exit;

  idx := FS.GetInodeByPath(PChar(aName));
  if idx < 1 then Exit;

  fsize := Data.Size;

  Result := FS.SetSize(idx, fsize);
  if Result < 0 then Exit;

  if fsize = 0 then
  begin
    Result := 0;
    Exit;
  end;

  FS.InodeMgr.LoadInodeBlocks(idx, Blocks);

  blockCount := fsize div FS.BlockSize;
  if (fsize and (FS.BlockSize - 1)) <> 0 then
    Inc(blockCount);

  if Blocks.level[0].Count < blockCount then Exit;

  SetLength(buff, QWord(blockCount) * FS.BlockSize);
  // ВИПРАВЛЕНО: обнуляємо буфер повністю замість читання старого вмісту блоків.
  // Це прибирає витік даних попереднього вмісту блоків у "хвості" останнього блоку
  // (байти від fsize до кінця блоку) і заодно економить зайві дискові читання.
  FillChar(buff[0], Length(buff), 0);

  pSource := Data.Memory;
  if (pSource <> nil) and (fsize > 0) then
    Move(pSource^, buff[0], fsize);

  for i := 0 to blockCount - 1 do
    FS.WriteBlock(Blocks.level[0].Data[i], @buff[QWord(i) * FS.BlockSize]);

  Result := 0;
end;


function qnx6_readDir(FS: TQNX6Fs; const aPath: string; out EntriesList: TDirEntryInfoArray): integer;
var
  idx, childIdx: DWord;
  inode, childInode: TQNX6_DInode;
  entries: TQNX6_ARawDirEntry;
  i, res, Count: integer;
  entryName: string;
begin
  SetLength(EntriesList, 0);
  Result := -ESysENOENT;
  if (FS = nil) or (aPath = '') then Exit;

  idx := FS.GetInodeByPath(PChar(aPath));
  if idx = 0 then Exit;

  inode := FS.GetInode(idx);

  if FpS_ISDIR(inode.mode) then
  begin
    res := FS.ReadDirectory(idx, entries);
    if res < 0 then Exit(res);

    SetLength(EntriesList, Length(entries));
    Count := 0;

    for i := 0 to High(entries) do
    begin
      entryName := FS.RawDirEntryGetName(entries[i]);

      if (entryName = '.') or (entryName = '..') then
        Continue;

      childIdx := entries[i].inode;
      if childIdx = 0 then Continue;

      // Отримуємо Inode запису для зчитування mode та size
      childInode := FS.GetInode(childIdx);

      EntriesList[Count].Name := entryName;
      EntriesList[Count].InodeIdx := childIdx;
      EntriesList[Count].Mode := childInode.mode;
      EntriesList[Count].Size := childInode.size;
      EntriesList[Count].atime := childInode.atime;
      EntriesList[Count].ctime := childInode.ctime;
      EntriesList[Count].mtime := childInode.mtime;
      EntriesList[Count].uid := childInode.uid;
      EntriesList[Count].gid := childInode.gid;
      Inc(Count);
    end;

    SetLength(EntriesList, Count);
    // Обрізаємо масив до фактичної кількості
    Result := 0;
  end
  else
    Result := -ESysENOTDIR;
end;

end.
