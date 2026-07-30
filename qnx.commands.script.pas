unit QNX.Commands.Script;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, qnx6, qnx6.types, QNX.Utils, uScript;

type
  TMkDirCommand = class(TBasicCommand)
  private
    FFS: TQNX6Fs;
  public
    constructor Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
    function Execute(const Args: array of string): integer; override;
  end;

  TPushCommand = class(TBasicCommand)
  private
    FFS: TQNX6Fs;
  public
    constructor Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
    function Execute(const Args: array of string): integer; override;
  end;

  TTouchCommand = class(TBasicCommand)
  private
    FFS: TQNX6Fs;
  public
    constructor Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
    function Execute(const Args: array of string): integer; override;
  end;

  TChmodCommand = class(TBasicCommand)
  private
    FFS: TQNX6Fs;
  public
    constructor Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
    function Execute(const Args: array of string): integer; override;
  end;

  TChownCommand = class(TBasicCommand)
  private
    FFS: TQNX6Fs;
    procedure ParseOwnerGroup(const Arg: string; var Uid, Gid: integer; var Valid: boolean);
  public
    constructor Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
    function Execute(const Args: array of string): integer; override;
  end;

  TReplaceCommand = class(TBasicCommand)
  private
    FFS: TQNX6Fs;
  public
    constructor Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
    function Execute(const Args: array of string): integer; override;
  end;

  TRemoveAppCommand = class(TBasicCommand)
  private
    FFS: TQNX6Fs;
  public
    constructor Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
    function Execute(const Args: array of string): integer; override;
  end;

  TRmCommand = class(TBasicCommand)
  private
    FFS: TQNX6Fs;
  public
    constructor Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
    function Execute(const Args: array of string): integer; override;
  end;

  TAddStringCommand = class(TBasicCommand)
  private
    FFS: TQNX6Fs;
  public
    constructor Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
    function Execute(const Args: array of string): integer; override;
  end;


function ApplyChmod(FS: TQNX6Fs; const Path: string; Mode: integer; Recursive: boolean): integer;
function ApplyChown(FS: TQNX6Fs; const Path: string; Uid, Gid: integer; Recursive: boolean): integer;

implementation

uses CLI.Console;

function ApplyChmodByInode(FS: TQNX6Fs; idx: DWord; const Path: string; Mode: integer;
  Recursive: boolean): integer; forward;

function ApplyChmod(FS: TQNX6Fs; const Path: string; Mode: integer; Recursive: boolean): integer;
var
  idx: DWord;
begin
  Result := -1;
  if FS = nil then Exit;

  // Резолвимо шлях у inode РІВНО ОДИН РАЗ — тут, на вході.
  idx := FS.GetInodeByPath(PChar(Path));
  if idx = 0 then
  begin
    TConsole.WriteLn(Format('chmod error: path "%s" not found', [Path]));
    Exit;
  end;
  TConsole.WriteLn(Format('chmod: mode set to %s for "%s"', [OctStr(Mode and $0FFF, 4), Path]));

  Result := ApplyChmodByInode(FS, idx, Path, Mode, Recursive);
end;

function ApplyChmodByInode(FS: TQNX6Fs; idx: DWord; const Path: string; Mode: integer;
  Recursive: boolean): integer;
var
  i, c: integer;
  inode: TQNX6_DInode;
  RDI: TQNX6_ARawDirEntry;
  Name, ChildPath, BasePath: string;
  hadError: boolean;
begin
  hadError := False;
  inode := FS.GetInode(idx);

  if Recursive and FpS_ISDIR(inode.mode) then
  begin
    //    TConsole.WriteLn(Format('chmod: mode set to %s for "%s"', [OctStr(Mode and $0FFF, 4), Path]));
    c := FS.ReadDirectory(idx, RDI);
    if c < 0 then
    begin
      TConsole.WriteLn(Format('chmod error: cannot read directory "%s"', [Path]));
      hadError := True;
    end
    else if c > 0 then
    begin
      BasePath := EnsurePOSIXTrailingSlash(Path);
      for i := 0 to Pred(c) do
      begin
        Name := FS.RawDirEntryGetName(RDI[i]);
        if (Name <> '.') and (Name <> '..') then
        begin
          ChildPath := BasePath + Name;
          // лише для логів/повідомлень про помилки
          // ВИПРАВЛЕНО: не резолвимо ChildPath через GetInodeByPath —
          // inode дочірнього елемента вже відомий з RDI[i].inode.
          if ApplyChmodByInode(FS, RDI[i].inode, ChildPath, Mode, True) <> 0 then
            hadError := True;
        end;
      end;
    end;
    SetLength(RDI, 0);
  end;

  inode.mode := (inode.mode and not $0FFF) or (Mode and $0FFF);
  FS.SetInode(idx, inode);

  if hadError then
    Result := -1
  else
    Result := 0;
end;

function ApplyChown(FS: TQNX6Fs; const Path: string; Uid, Gid: integer; Recursive: boolean): integer;
var
  idx: DWord;
  i, c: integer;
  inode: TQNX6_DInode;
  RDI: TQNX6_ARawDirEntry;
  Name, ChildPath, BasePath: string;
begin
  Result := -1;
  if FS = nil then Exit;

  idx := FS.GetInodeByPath(PChar(Path));
  if idx > 0 then
  begin
    inode := FS.GetInode(idx);

    if Recursive and FpS_ISDIR(inode.mode) then
    begin
      c := FS.ReadDirectory(idx, RDI);
      if c > 0 then
      begin
        BasePath := EnsurePOSIXTrailingSlash(Path);
        for i := 0 to Pred(c) do
        begin
          Name := FS.RawDirEntryGetName(RDI[i]);
          if (Name <> '.') and (Name <> '..') then
          begin
            ChildPath := BasePath + Name;
            // Передаємо True для рекурсивних викликів всередині
            ApplyChown(FS, ChildPath, Uid, Gid, True);
          end;
        end;
      end;
      SetLength(RDI, 0);
    end;

    if Uid <> -1 then inode.uid := cardinal(Uid);
    if Gid <> -1 then inode.gid := cardinal(Gid);

    FS.SetInode(idx, inode);

    // Виводимо лог для конкретного файлу/папки лише у нерекурсивному режимі
    if not Recursive then
      TConsole.WriteLn(Format('chown: owner/group set to %d:%d for "%s"', [Uid, Gid, Path]));

    Result := 0;
  end
  else
    TConsole.WriteLn(Format('chown error: path "%s" not found', [Path]));
end;

function ReplaceInStream(Stream: TMemoryStream; const OldStr, NewStr: rawbytestring): boolean;
var
  DataStr, ModifiedStr: rawbytestring;
begin
  Result := False;
  if (Stream = nil) or (Stream.Size = 0) or (OldStr = '') then Exit;

  Stream.Position := 0;
  SetLength(DataStr, Stream.Size);
  Stream.Read(DataStr[1], Stream.Size);

  ModifiedStr := StringReplace(DataStr, OldStr, NewStr, [rfReplaceAll]);

  if DataStr <> ModifiedStr then
  begin
    Stream.Clear;
    if Length(ModifiedStr) > 0 then
      Stream.Write(ModifiedStr[1], Length(ModifiedStr));
    Result := True;
  end;

  Stream.Position := 0;
end;

{ TMkDirCommand }

constructor TMkDirCommand.Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
begin
  inherited Create(AName, AHelp, AUsage);
  FFS := AFS;
end;

function TMkDirCommand.Execute(const Args: array of string): integer;
var
  TargetDir: string;
  IsRecursive: boolean;
begin
  Result := -1;
  IsRecursive := False;
  TargetDir := '';

  if (Length(Args) = 2) and (Args[0] = '-p') then
  begin
    IsRecursive := True;
    TargetDir := Args[1];
  end
  else if Length(Args) = 1 then
  begin
    TargetDir := Args[0];
  end
  else
  begin
    TConsole.WriteLn('Error: Wrong arguments count.');
    TConsole.WriteLn('Usage: mkdir [-p] <directory_path>');
    Exit(1);
  end;

  TargetDir := Path2QNX(TargetDir);
  if (TargetDir = '') or (TargetDir[1] <> '/') then
    TargetDir := '/' + TargetDir;

  if qnx6_MkDir(FFS, TargetDir, IsRecursive) then
  begin
    TConsole.WriteLn('Successfully created directory: "' + TargetDir + '"');
    Result := 0;
  end
  else
    TConsole.WriteLn('Error: Failed to create directory "' + TargetDir + '"');
end;

{ TTouchCommand }

constructor TTouchCommand.Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
begin
  inherited Create(AName, AHelp, AUsage);
  FFS := AFS;
end;

function TTouchCommand.Execute(const Args: array of string): integer;
var
  Target: string;
begin
  Result := -1;

  if Length(Args) = 1 then
    Target := Args[0]
  else
  begin
    TConsole.WriteLn('Error: Wrong arguments count.');
    TConsole.WriteLn('Usage: touch <file name>');
    Exit(1);
  end;

  Target := Path2QNX(Target);
  if (Target = '') or (Target[1] <> '/') then
    Target := '/' + Target;

  if FFS.CreateFile(PChar(Target), &666) = 0 then
  begin
    TConsole.WriteLn('Successfully touched file: "' + Target + '"');
    Result := 0;
  end
  else
    TConsole.WriteLn('Error: Failed to create file "' + Target + '"');
end;

{ TPushCommand }

constructor TPushCommand.Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
begin
  inherited Create(AName, AHelp, AUsage);
  FFS := AFS;
end;

function TPushCommand.Execute(const Args: array of string): integer;
var
  src, dst, inPath, outPath, relPath: string;
  DL: TStringList;
  Stream: TMemoryStream;
  isDir: boolean;
  CopiedCount: integer;
begin
  Result := -1;

  if Length(Args) <> 2 then
  begin
    TConsole.WriteLn('Usage: push <local_src_path> <qnx_dst_path>');
    Exit(1);
  end;

  src := ExpandFileName(Args[0]);
  isDir := DirectoryExists(src);

  if not isDir and not FileExists(src) then
  begin
    TConsole.WriteLn('Error: Source path "' + src + '" does not exist.');
    Exit(2);
  end;

  dst := Args[1];
  if (dst = '') or (dst[1] <> '/') then
    dst := '/' + dst;

  if not isDir then
  begin
    if dst.EndsWith('/') then
    begin
      qnx6_MkDir(FFS, dst, True);
      dst := dst + ExtractFileName(src);
    end
    else
      qnx6_MkDir(FFS, ExtractPOSIXFilePath(dst), True);

    Stream := TMemoryStream.Create;
    try
      try
        Stream.LoadFromFile(src);
        FFS.CreateFile(PChar(dst), &666);
        if qnx6_writeFile(FFS, dst, Stream) <> 0 then
        begin
          TConsole.WriteLn('Failed to write file: ' + dst);
          Exit(3);
        end;
        TConsole.WriteLn('Pushed file: "' + src + '" -> "' + dst + '"');
      except
        on E: Exception do
        begin
          TConsole.WriteLn('Error copying file: ' + E.Message);
          Exit(4);
        end;
      end;
    finally
      FreeAndNil(Stream);
    end;

    Exit(0);
  end;

  TConsole.WriteLn('Pushing directory structure from "' + src + '" to "' + dst + '"...');
  qnx6_MkDir(FFS, dst, True);

  DL := FindAllDirectories(src);
  try
    if Assigned(DL) then
    begin
      for inPath in DL do
      begin
        relPath := ExtractRelativePath(IncludeTrailingPathDelimiter(src), inPath);
        if (relPath = '') or (relPath = '.') then Continue;

        outPath := Path2QNX(EnsurePOSIXTrailingSlash(dst) + relPath);
        qnx6_MkDir(FFS, outPath, True);
        TConsole.WriteLn('Created directory: ' + outPath);
      end;
    end;
  finally
    FreeAndNil(DL);
  end;

  CopiedCount := 0;
  Stream := TMemoryStream.Create;
  try
    try
      DL := FindAllFiles(src, '*');
      if Assigned(DL) then
      begin
        for inPath in DL do
        begin
          relPath := ExtractRelativePath(IncludeTrailingPathDelimiter(src), inPath);
          outPath := Path2QNX(EnsurePOSIXTrailingSlash(dst) + relPath);

          qnx6_MkDir(FFS, ExtractPOSIXFilePath(outPath), True);

          FFS.CreateFile(PChar(outPath), &666);
          try
            Stream.Clear;
            Stream.LoadFromFile(inPath);
            if qnx6_writeFile(FFS, outPath, Stream) <> 0 then
              TConsole.WriteLn('Failed to write file: ' + outPath)
            else
            begin
              TConsole.WriteLn('Pushed: ' + relPath + ' -> ' + outPath);
              Inc(CopiedCount);
            end;
          except
            on E: Exception do
              TConsole.WriteLn('Error reading local file "' + inPath + '": ' + E.Message);
          end;
        end;
      end;
      TConsole.WriteLn(Format('Push completed. Total files pushed: %d', [CopiedCount]));
    except
      on E: Exception do
      begin
        TConsole.WriteLn('Error during directory file scanning: ' + E.Message);
        Exit(5);
      end;
    end;
  finally
    FreeAndNil(DL);
    FreeAndNil(Stream);
  end;

  Result := 0;
end;

{ TChmodCommand }

constructor TChmodCommand.Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
begin
  inherited Create(AName, AHelp, AUsage);
  FFS := AFS;
end;

function TChmodCommand.Execute(const Args: array of string): integer;
var
  Mode: integer;
  TargetFile: string;
  IsRecursive: boolean;
  ModeStr: string;
begin
  IsRecursive := False;
  ModeStr := '';
  TargetFile := '';

  if (Length(Args) = 3) and (Args[0] = '-R') then
  begin
    IsRecursive := True;
    ModeStr := Args[1];
    TargetFile := Args[2];
  end
  else if Length(Args) = 2 then
  begin
    ModeStr := Args[0];
    TargetFile := Args[1];
  end
  else
  begin
    TConsole.WriteLn('Error: Wrong arguments count.');
    TConsole.WriteLn('Usage: chmod [-R] <mode> <filename/directory>');
    Exit(1);
  end;

  try
    if (Length(ModeStr) > 0) and (ModeStr[1] <> '&') then
      Mode := StrToInt('&' + ModeStr)
    else
      Mode := StrToInt(ModeStr);
  except
    on E: EConvertError do
    begin
      TConsole.WriteLn('Error: Wrong mode format "' + ModeStr + '". Use octal format (e.g., 755).');
      Exit(2);
    end;
  end;

  Result := ApplyChmod(FFS, TargetFile, Mode, IsRecursive);
  if Result = 0 then
  begin
    if IsRecursive then
      TConsole.WriteLn(Format('chmod: recursively applied mode %s to "%s"',
        [OctStr(Mode and $0FFF, 4), TargetFile]))
    else
      TConsole.WriteLn('chmod operation completed successfully.');
  end
  else
    TConsole.WriteLn('chmod operation failed.');
end;

{ TChownCommand }

constructor TChownCommand.Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
begin
  inherited Create(AName, AHelp, AUsage);
  FFS := AFS;
end;

procedure TChownCommand.ParseOwnerGroup(const Arg: string; var Uid, Gid: integer; var Valid: boolean);
var
  ColonPos: integer;
  UidStr, GidStr: string;
begin
  Valid := True;
  ColonPos := Pos(':', Arg);
  if ColonPos = 0 then ColonPos := Pos('.', Arg);

  try
    if ColonPos > 0 then
    begin
      UidStr := Copy(Arg, 1, ColonPos - 1);
      GidStr := Copy(Arg, ColonPos + 1, Length(Arg) - ColonPos);

      if UidStr = '' then Uid := -1
      else
        Uid := StrToInt(UidStr);

      if GidStr = '' then Gid := -1
      else
        Gid := StrToInt(GidStr);
    end
    else
    begin
      Uid := StrToInt(Arg);
      Gid := -1;
    end;
  except
    on E: EConvertError do Valid := False;
  end;
end;

function TChownCommand.Execute(const Args: array of string): integer;
var
  Uid, Gid: integer;
  TargetFile: string;
  IsRecursive: boolean;
  OwnerGroupStr: string;
  IsValidFormat: boolean;
begin
  IsRecursive := False;
  OwnerGroupStr := '';
  TargetFile := '';

  if (Length(Args) = 3) and (Args[0] = '-R') then
  begin
    IsRecursive := True;
    OwnerGroupStr := Args[1];
    TargetFile := Args[2];
  end
  else if Length(Args) = 2 then
  begin
    OwnerGroupStr := Args[0];
    TargetFile := Args[1];
  end
  else
  begin
    TConsole.WriteLn('Error: Wrong arguments count.');
    TConsole.WriteLn('Usage: chown [-R] [owner][:group] <filename/directory>');
    Exit(1);
  end;

  ParseOwnerGroup(OwnerGroupStr, Uid, Gid, IsValidFormat);
  if not IsValidFormat then
  begin
    TConsole.WriteLn('Error: Wrong owner/group format "' + OwnerGroupStr + '"');
    Exit(2);
  end;

  Result := ApplyChown(FFS, TargetFile, Uid, Gid, IsRecursive);
  if Result = 0 then
  begin
    if IsRecursive then
      TConsole.WriteLn(Format('chown: recursively applied owner/group %d:%d to "%s"',
        [Uid, Gid, TargetFile]))
    else
      TConsole.WriteLn('chown operation completed successfully.');
  end
  else
    TConsole.WriteLn('chown operation failed.');
end;

{ TReplaceCommand }

constructor TReplaceCommand.Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
begin
  inherited Create(AName, AHelp, AUsage);
  FFS := AFS;
end;

function TReplaceCommand.Execute(const Args: array of string): integer;
var
  TargetFile, sOld, sNew: string;
  msData: TMemoryStream;
begin
  if Length(Args) <> 3 then
  begin
    TConsole.WriteLn('Error: Wrong arguments count.');
    TConsole.WriteLn('Usage: replace <filename/directory> <old value> <new value>');
    Exit(1);
  end;

  TargetFile := Args[0];
  sOld := Args[1];
  sNew := Args[2];

  TConsole.WriteLn(Format('Replacing "%s" with "%s" in file "%s"...', [sOld, sNew, TargetFile]));

  msData := TMemoryStream.Create;
  try
    if qnx6_readFile(FFS, TargetFile, msData) <> 0 then
    begin
      TConsole.WriteLn(Format('Error: File "%s" not found or cannot be read.', [TargetFile]));
      Exit(1);
    end;

    if ReplaceInStream(msData, sOld, sNew) then
    begin
      if qnx6_writeFile(FFS, TargetFile, msData) <> 0 then
      begin
        TConsole.WriteLn(Format('Error: File "%s" write error.', [TargetFile]));
        Exit(1);
      end;
      TConsole.WriteLn(Format('Success: File "%s" updated.', [TargetFile]));
    end
    else
    begin
      TConsole.WriteLn(Format('Notice: Target string "%s" was not found in "%s". File unchanged.',
        [sOld, TargetFile]));
    end;

    Result := 0;
  finally
    FreeAndNil(msData);
  end;
end;

{ TRemoveAppCommand }

constructor TRemoveAppCommand.Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
begin
  inherited Create(AName, AHelp, AUsage);
  FFS := AFS;
end;

const
  PATH_REGISTERED_APPS = '/var/pps/system/installer/registeredapps/applications';
  PATH_APP_DETAILS = '/var/pps/system/installer/appdetails';
  PATH_APPS = '/apps';

type
  TRegList = record
    Name: string;
    Data: TStringList;
    Changed: boolean;
  end;


// Допоміжна функція для завантаження TStringList через TMemoryStream
function LoadPPSList(FS: TQNX6Fs; const FilePath: string; TargetList: TStringList;
  Stream: TMemoryStream): boolean;
begin
  Result := False;
  Stream.Clear;
  if qnx6_readFile(FS, FilePath, Stream) = 0 then
  begin
    Stream.Position := 0;
    TargetList.LoadFromStream(Stream);
    Result := True;
  end;
end;

// Допоміжна функція для збереження TStringList через TMemoryStream
function SavePPSList(FS: TQNX6Fs; const FilePath: string; SourceList: TStringList;
  Stream: TMemoryStream): boolean;
begin
  Stream.Clear;
  SourceList.SaveToStream(Stream);
  Stream.Position := 0;
  Result := qnx6_writeFile(FS, FilePath, Stream) = 0;
end;

function TRemoveAppCommand.Execute(const Args: array of string): integer;
var
  i, j, k: integer;
  BlackList, Registered: TStringList;
  Details: array of TRegList;
  blacklisted_app, AppPath, CleanArg: string;
  app_details, apps: TDirEntryInfoArray;
  ms: TMemoryStream;
  FoundInApps, RegChanged: boolean;
begin
  Result := -1;

  if FFS = nil then
  begin
    TConsole.WriteLn('Error: File system context is not initialized.');
    Exit;
  end;

  BlackList := TStringList.Create;
  Registered := TStringList.Create;
  ms := TMemoryStream.Create;
  try
    // 1. Парсинг аргументів
    for i := 0 to Length(Args) - 1 do
    begin
      CleanArg := Trim(Args[i]);
      if CleanArg <> '' then
        BlackList.Add(CleanArg);
    end;

    if BlackList.Count = 0 then
    begin
      TConsole.WriteLn('Usage: removeapp <app_name_1> [<app_name_2> ...]');
      Exit(1);
    end;

    // 2. Зчитування registeredapps
    LoadPPSList(FFS, PATH_REGISTERED_APPS, Registered, ms);

    // 3. Зчитування appdetails
    if qnx6_readDir(FFS, PATH_APP_DETAILS, app_details) <> 0 then
    begin
      TConsole.WriteLn('Error: Unable to read ' + PATH_APP_DETAILS);
      Exit;
    end;

    SetLength(Details, Length(app_details));
    for i := 0 to High(app_details) do
    begin
      Details[i].Name := app_details[i].Name;
      Details[i].Data := TStringList.Create;
      Details[i].Changed := False;

      LoadPPSList(FFS, PATH_APP_DETAILS + '/' + Details[i].Name, Details[i].Data, ms);
    end;

    // 4. Зчитування каталогу /apps та початок обробки
    if qnx6_readDir(FFS, PATH_APPS, apps) = 0 then
    begin
      TConsole.WriteLn(Format('Starting application removal for %d targets...', [BlackList.Count]));
      RegChanged := False;

      // --- ОСНОВНА ОБРОБКА В ПАМ'ЯТІ ---
      for blacklisted_app in BlackList do
      begin
        // Очищення Registered
        for j := Registered.Count - 1 downto 0 do
        begin
          if Pos(blacklisted_app, Registered[j]) > 0 then
          begin
            Registered.Delete(j);
            RegChanged := True;
          end;
        end;

        // Очищення Details
        for j := 0 to High(Details) do
        begin
          for k := Details[j].Data.Count - 1 downto 0 do
          begin
            if Pos(blacklisted_app, Details[j].Data[k]) > 0 then
            begin
              Details[j].Data.Delete(k);
              Details[j].Changed := True;
            end;
          end;
        end;

        // Видалення фізичних папок з /apps
        FoundInApps := False;
        for j := 0 to High(apps) do
        begin
          if Pos(blacklisted_app, apps[j].Name) > 0 then
          begin
            FoundInApps := True;
            AppPath := PATH_APPS + '/' + apps[j].Name;
            if qnx6_RmDir(FFS, AppPath, True) then
              TConsole.WriteLn(Format('"%s" removed from %s', [apps[j].Name, PATH_APPS]))
            else
              TConsole.WriteLn(Format('Error removing "%s" from %s', [apps[j].Name, PATH_APPS]));
          end;
        end;

        if not FoundInApps then
          TConsole.WriteLn(Format('"%s" not found in %s', [blacklisted_app, PATH_APPS]));
      end;

      // --- ЗБЕРЕЖЕННЯ ЗМІН В ФС ---
      if RegChanged then
        SavePPSList(FFS, PATH_REGISTERED_APPS, Registered, ms);

      for j := 0 to High(Details) do
      begin
        if Details[j].Changed then
        begin
          AppPath := PATH_APP_DETAILS + '/' + Details[j].Name;

          if Details[j].Data.Count = 0 then
            qnx6_Rm(FFS, AppPath)
          else
            SavePPSList(FFS, AppPath, Details[j].Data, ms);
        end;
      end;

      TConsole.WriteLn('Application removal process finished successfully.');
      Result := 0;
    end;

  finally
    for i := 0 to High(Details) do
      if Details[i].Data <> nil then
        FreeAndNil(Details[i].Data);

    FreeAndNil(ms);
    FreeAndNil(Registered);
    FreeAndNil(BlackList);
  end;
end;

constructor TRmCommand.Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
begin
  inherited Create(AName, AHelp, AUsage);
  FFS := AFS;
end;


function TRmCommand.Execute(const Args: array of string): integer;
var
  i: integer;
  s: string;
  Recursive: boolean;
  Targets: TStringList;
  SuccessCount, FailCount: integer;
begin
  Result := 0;
  Recursive := False;

  if FFS = nil then
  begin
    TConsole.WriteLn('rm: File system context is not initialized.');
    Exit(1);
  end;

  Targets := TStringList.Create;
  try
    // Парсинг аргументів та прапорців
    for i := 0 to Length(Args) - 1 do
    begin
      s := Trim(Args[i]);
      if s = '' then Continue;

      if (s = '-r') or (s = '-R') or (s = '-rf') or (s = '-fr') then
        Recursive := True
      else if (Length(s) > 0) and (s[1] <> '-') then
        Targets.Add(s);
    end;

    if Targets.Count = 0 then
    begin
      TConsole.WriteLn('rm: missing operand');
      Exit(1);
    end;

    SuccessCount := 0;
    FailCount := 0;

    for i := 0 to Targets.Count - 1 do
    begin
      s := Targets[i];

      if Recursive then
      begin
        if qnx6_RmDir(FFS, s, True) then
          Inc(SuccessCount)
        else
        begin
          TConsole.WriteLn(Format('rm: cannot remove ''%s'': Failed to remove directory or file', [s]));
          Inc(FailCount);
        end;
      end
      else
      begin
        if qnx6_Rm(FFS, s) then
          Inc(SuccessCount)
        else
        begin
          // Спроба видалити як порожній каталог, якщо це не звичайний файл
          if qnx6_RmDir(FFS, s, False) then
            Inc(SuccessCount)
          else
          begin
            TConsole.WriteLn(Format('rm: cannot remove ''%s'': No such file or Directory is not empty',
              [s]));
            Inc(FailCount);
          end;
        end;
      end;
    end;

    if FailCount > 0 then
      Result := 1;
  finally
    FreeAndNil(Targets);
  end;
end;


constructor TAddStringCommand.Create(const AName, AHelp, AUsage: string; AFS: TQNX6Fs);
begin
  inherited Create(AName, AHelp, AUsage);
  FFS := AFS;
end;

function TAddStringCommand.Execute(const Args: array of string): integer;
var
  ms: TMemoryStream;
  sl: TStringList;
  FilePath, NewString: string;
begin
  Result := -1;

  if FFS = nil then
  begin
    TConsole.WriteLn('Error: File system context is not initialized.');
    Exit;
  end;

  if Length(Args) <> 2 then
  begin
    TConsole.WriteLn('Usage: addstring <file> <string>');
    Exit(1);
  end;

  FilePath := Path2QNX(Trim(Args[0]));
  NewString := Args[1];

  ms := TMemoryStream.Create;
  sl := TStringList.Create;
  try
    // Спробуємо прочитати файл. Якщо його немає — буде створено новий список.
    if qnx6_readFile(FFS, FilePath, ms) = 0 then
    begin
      ms.Position := 0;
      sl.LoadFromStream(ms);
    end;

    // Перевіряємо на наявність дубліката
    if sl.IndexOf(NewString) <> -1 then
    begin
      TConsole.WriteLn(Format('String "%s" already exists in "%s". Skipping.', [NewString, FilePath]));
      Exit(0);
    end;

    // Додаємо новий рядок
    sl.Add(NewString);

    // Підготовлюємо потік для запису
    ms.Clear;
    sl.SaveToStream(ms);
    ms.Position := 0;

    // Записуємо оновлений зміст назад у ФС
    if qnx6_writeFile(FFS, FilePath, ms) = 0 then
    begin
      TConsole.WriteLn(Format('"%s" added to "%s"', [NewString, FilePath]));
      Result := 0;
    end
    else
      TConsole.WriteLn(Format('Error: Failed to write to file "%s"', [FilePath]));

  finally
    FreeAndNil(sl);
    FreeAndNil(ms);
  end;
end;

end.
