unit uAutoloader;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, uMisc;

type
  TFileType = (ftUnknown, ftUser, ftOS, ftRadio, ftIFS);

  TPEAutoloaderFileInfo = record
    Offset: int64;
    Size: int64;
    FileType: TFileType;
    Index: integer;
  end;

  TPEAutoloaderFileInfoArray = array of TPEAutoloaderFileInfo;

function AnalyzePEAutoloaderFiles(SourceStream: TFileStream): TPEAutoloaderFileInfoArray; overload;
function AnalyzePEAutoloaderFiles(const FileName: string): TPEAutoloaderFileInfoArray; overload;
procedure ExtractBlackBerryAutoloaderFromPE(const FileName: string);

function MakeAutoloader(oFile: string; const iFiles: TStringList; capexe: string = 'cap.exe';
  ver: integer = 2; cb: TProgressCallback = nil): boolean;

function ExtractCap(inFile, outFile: string): boolean;

implementation

uses PEFile, Math, FileUtil;

const
  START_SIGNATURE_DWORD = $97C5D59C; // Little endian signature
  PFCQ_SIGNATURE = $71636670; // 'pfcq'
  SCAN_BLOCK_SIZE = 65536;
  MAX_FILES = 10;

function ReadFileCount(Stream: TStream): int64;
const
  MAX_OFFSET_SEARCH = 1000;
var
  OffsetTablePos: int64;
  SearchAttempts: integer;
  PosBeforeSearch: int64;
  FileCountVal: DWord;
begin
  Result := 0;
  SearchAttempts := 0;
  PosBeforeSearch := Stream.Position;

  repeat
    if Stream.Position + SizeOf(int64) > Stream.Size then
      raise Exception.Create('Unexpected end of file while searching for offset table');

    if Stream.Read(OffsetTablePos, SizeOf(int64)) <> SizeOf(int64) then
      raise Exception.Create('Error reading offset table position');

    if (OffsetTablePos > PosBeforeSearch) and (OffsetTablePos < Stream.Size) and
      (Abs(OffsetTablePos - Stream.Position) < 1000) then
    begin
      if Stream.Position >= 16 then
        Stream.Position := Stream.Position - 16
      else
        Stream.Position := 0;

      // Читаємо значення FileCount
      if Stream.Read(FileCountVal, SizeOf(QWord)) <> SizeOf(QWord) then
        raise Exception.Create('Error reading file count');

      Result := FileCountVal;
      Exit;
    end;

    Inc(SearchAttempts);
  until SearchAttempts >= MAX_OFFSET_SEARCH;

  raise Exception.Create('Failed to find valid file count after max search attempts');
end;

function FindSignature(const Stream: TStream; StartPos: int64): int64;
var
  Buffer: TBytes;
  Position, I: int64;
  BytesRead, SearchSize: integer;
  DWordPtr1, DWordPtr2: PDWORD;
begin
  Result := -1;
  SetLength(Buffer, SCAN_BLOCK_SIZE);
  Position := StartPos;

  while Position <= Stream.Size - 20 do
  begin
    Stream.Position := Position;
    BytesRead := Stream.Read(Buffer[0], Length(Buffer));
    if BytesRead < 20 then Break;

    SearchSize := BytesRead - 19;
    for I := 0 to SearchSize - 1 do
    begin
      DWordPtr1 := PDWORD(@Buffer[I]);
      DWordPtr2 := PDWORD(@Buffer[I + 8]);

      if (DWordPtr1^ = START_SIGNATURE_DWORD) and (DWordPtr2^ = START_SIGNATURE_DWORD) then
      begin
        Result := Position + I + 20;
        Exit;
      end;
    end;

    Position := Position + SearchSize;
  end;
end;

function DetermineFileType(const Buffer: array of byte): TFileType;
var
  I, MaxLen: integer;
  DWordPtr: PDWORD;
begin
  Result := ftUnknown;
  MaxLen := Min(Length(Buffer), 64);
  if MaxLen < 16 then Exit;

  for I := 0 to MaxLen - 16 do
  begin
    DWordPtr := PDWORD(@Buffer[I]);
    if DWordPtr^ = PFCQ_SIGNATURE then
    begin
      case Buffer[I + 12] of
        5: Result := ftUser;
        6: Result := ftOS;
        8: Result := ftIFS;
        12: Result := ftRadio;
      end;
      Break;
    end;
  end;
end;

function GetFileExtension(FileType: TFileType; Index: integer): string;
begin
  case FileType of
    ftUser: Result := Format('.%d@User.signed', [Index]);
    ftOS: Result := Format('.%d@OS.signed', [Index]);
    ftIFS: Result := Format('.%d@IFS.signed', [Index]);
    ftRadio: Result := Format('.%d@Radio.signed', [Index]);
    else
      Result := Format('.%d.signed', [Index]);
  end;
end;

function AnalyzePEAutoloaderFiles(SourceStream: TFileStream): TPEAutoloaderFileInfoArray;
var
  PeEndOffset, SignaturePos: int64;
  FileCount, I: int64;
  Offsets: array of int64;
  Buffer: TBytes;
begin
  PeEndOffset := GetPEEndOffset(SourceStream);
  if PeEndOffset = 0 then
    raise Exception.Create('Invalid or corrupted PE file');

  SignaturePos := FindSignature(SourceStream, PeEndOffset);
  if SignaturePos < 0 then
    raise Exception.Create('BlackBerry autoloader signature not found after PE data');

  SourceStream.Position := SignaturePos;

  FileCount := ReadFileCount(SourceStream);
  if (FileCount < 1) or (FileCount > MAX_FILES) then
    raise Exception.CreateFmt('Invalid file count: %d (expected 1-%d)', [FileCount, MAX_FILES]);

  SetLength(Offsets, FileCount + 1);
  for I := 0 to FileCount - 1 do
  begin
    if SourceStream.Read(Offsets[I], SizeOf(int64)) <> SizeOf(int64) then
      raise Exception.Create('Error reading file offset');
    if (Offsets[I] < 0) or (Offsets[I] >= SourceStream.Size) then
      raise Exception.CreateFmt('Invalid file offset %d: %d', [I, Offsets[I]]);
  end;
  Offsets[FileCount] := SourceStream.Size;

  SetLength(Result, FileCount);

  for I := 0 to FileCount - 1 do
  begin
    Result[I].Offset := Offsets[I];
    Result[I].Size := Offsets[I + 1] - Offsets[I];
    Result[I].Index := I;

    SourceStream.Position := Offsets[I];
    SetLength(Buffer, Min(64, Result[I].Size));
    if Length(Buffer) > 0 then
      SourceStream.ReadBuffer(Buffer[0], Length(Buffer));

    Result[I].FileType := DetermineFileType(Buffer);
  end;
end;

function AnalyzePEAutoloaderFiles(const FileName: string): TPEAutoloaderFileInfoArray;
var
  SourceStream: TFileStream;
begin
  SourceStream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    Result := AnalyzePEAutoloaderFiles(SourceStream);
  finally
    SourceStream.Free;
  end;
end;

procedure ExtractPEAutoloaderFiles(const FileName: string; const Files: TPEAutoloaderFileInfoArray);
var
  SourceStream, OutputFile: TFileStream;
  OutputFileName: string;
  I: integer;
begin
  if Length(Files) = 0 then Exit;

  SourceStream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    Writeln(Format('Extracting %d files from %s...', [Length(Files), ExtractFileName(FileName)]));

    for I := 0 to High(Files) do
    begin
      if Files[I].Size <= 0 then
      begin
        Writeln(Format('Skipping file %d: invalid size (%d)', [Files[I].Index, Files[I].Size]));
        Continue;
      end;

      SourceStream.Position := Files[I].Offset;
      OutputFileName := ChangeFileExt(FileName, GetFileExtension(Files[I].FileType, Files[I].Index));

      OutputFile := TFileStream.Create(OutputFileName, fmCreate);
      try
        OutputFile.CopyFrom(SourceStream, Files[I].Size);
        Writeln(Format('Extracted: %s (%s bytes)', [ExtractFileName(OutputFileName),
          FormatFloat('#,##0', Files[I].Size)]));
      finally
        OutputFile.Free;
      end;
    end;

    Writeln('Extraction completed successfully.');
  finally
    SourceStream.Free;
  end;
end;

procedure ExtractBlackBerryAutoloaderFromPE(const FileName: string);
var
  files: TPEAutoloaderFileInfoArray;
begin
  files := AnalyzePEAutoloaderFiles(FileName);
  ExtractPEAutoloaderFiles(FileName, files);
end;

function GetCapSize(Stream: TStream): int64;
var
  PeEnd, SigPos: int64;
begin
  Result := Stream.Size;
  PeEnd := GetPEEndOffset(Stream);
  if PeEnd = 0 then Exit;

  SigPos := FindSignature(Stream, PeEnd);
  if SigPos >= 20 then
    Result := SigPos - 20;
end;

function ExtractCap(inFile, outFile: string): boolean;
var
  capSize: int64;
  outStream, cap: TFileStream;
begin
  Result := False;
  cap := TFileStream.Create(inFile, fmOpenRead or fmShareDenyWrite);
  try
    capSize := GetCapSize(cap);
    if capSize >= cap.Size then Exit;

    cap.Position := 0;
    outStream := TFileStream.Create(outFile, fmCreate or fmShareExclusive);
    try
      outStream.CopyFrom(cap, capSize);
      Result := True;
    finally
      outStream.Free;
    end;
  finally
    cap.Free;
  end;
end;

function MakeAutoloader(oFile: string; const iFiles: TStringList; capexe: string = 'cap.exe';
  ver: integer = 2; cb: TProgressCallback = nil): boolean;
var
  inStream, outStream, cap: TFileStream;
  off, capSize, xDelta: int64;
  i, c: integer;
  fn: string;
begin
  Result := False;
  if not FileExists(capexe) then
    raise Exception.CreateFmt('Base stub binary not found: %s', [capexe]);

  cap := TFileStream.Create(capexe, fmOpenRead or fmShareDenyWrite);
  try
    capSize := GetPEEndOffset(cap);
    if capSize = 0 then capSize := cap.Size;

    cap.Position := 0;
    outStream := TFileStream.Create(oFile, fmCreate or fmShareExclusive);
    try
      // 1. Копіюємо PE-заглушку (cap.exe)
      outStream.CopyFrom(cap, capSize);

      // 2. Пишемо сигнатуру
      outStream.WriteDWord(START_SIGNATURE_DWORD);
      outStream.WriteDWord(START_SIGNATURE_DWORD);
      outStream.WriteDWord(START_SIGNATURE_DWORD);

      xDelta := 52;
      if ver = 2 then
      begin
        Inc(xDelta, 80);
        for i := 0 to 19 do
          outStream.WriteDWord(0);
      end;

      c := iFiles.Count;
      outStream.WriteDWord(c);

      // 3. Розраховуємо та пишемо таблицю зміщень
      off := capSize + xDelta;
      for i := 0 to c - 1 do
      begin
        fn := iFiles.Strings[i];
        if not FileExists(fn) then
          raise Exception.CreateFmt('Input image file not found: %s', [fn]);

        outStream.WriteQWord(0);   // Reserved / Alignment
        outStream.WriteQWord(off); // 64-бітне зміщення файлу
        Inc(off, FileSize(fn));
      end;

      // Вирівнюємо заголовок до необхідного розміру
      while outStream.Position < capSize + xDelta do
        outStream.WriteDWord(0);

      // 4. Послідовно записуємо дані образиів
      for i := 0 to c - 1 do
      begin
        fn := iFiles.Strings[i];
        inStream := TFileStream.Create(fn, fmOpenRead or fmShareDenyWrite);
        try
          if Assigned(cb) then cb(fn, i, c);
          outStream.CopyFrom(inStream, inStream.Size);
        finally
          inStream.Free;
        end;
      end;

      if Assigned(cb) then cb(oFile, c, c);
      Result := True;
    finally
      outStream.Free;
    end;
  finally
    cap.Free;
  end;
end;

end.
