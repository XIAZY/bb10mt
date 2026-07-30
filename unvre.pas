unit NVRE;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils;

const
  NVRAM_BLOCK_MAGIC = $4552564E; // 'NVRE' (Little-Endian)

type
  TNVRAMBlockHeader = packed record
    unk1: word;
    BlockNum: word;
    Revision: DWord;
    DataCrc: DWord;
    unk2: DWord;
    BlockLen: DWord;
    DataLen: DWord;
    HdrCrc: DWord;
  end;

  TNVRAMBlock = record
    Header: TNVRAMBlockHeader;
    Data: TBytes;
    Magic: DWord;
  end;

function ReadNVRAMBlock(Stream: TStream): TNVRAMBlock;
function IsValidNVRAMBlock(const Block: TNVRAMBlock): boolean;

implementation

uses crc;

function ReadNVRAMBlock(Stream: TStream): TNVRAMBlock;
var
  HeaderSize: integer;
begin
  HeaderSize := SizeOf(TNVRAMBlockHeader);

  if Stream.Read(Result.Header, HeaderSize) <> HeaderSize then
    raise Exception.Create('Cannot read NVRAM header');

  SetLength(Result.Data, Result.Header.DataLen);

  if Result.Header.DataLen > 0 then
  begin
    if Stream.Read(Result.Data[0], Result.Header.DataLen) <> integer(Result.Header.DataLen) then
      raise Exception.Create('Cannot read NVRAM data');
  end;

  if Stream.Read(Result.Magic, SizeOf(DWord)) <> SizeOf(DWord) then
    raise Exception.Create('Cannot read NVRAM magic');
end;

function IsValidNVRAMBlock(const Block: TNVRAMBlock): boolean;
var
  CalcDataCRC, CalcHdrCRC: DWord;
  DataPtr: Pointer;
begin
  // Перевірка відповідності заявленого розміру та фактичної довжини масиву
  if DWord(Length(Block.Data)) <> Block.Header.DataLen then
    Exit(False);

  // Безпечне отримання вказівника на байти даних
  if Block.Header.DataLen > 0 then
    DataPtr := @Block.Data[0]
  else
    DataPtr := nil;

  // Обчислюємо CRC32 від Block.Data
  CalcDataCRC := crc32(0, DataPtr, Block.Header.DataLen);

  if CalcDataCRC <> Block.Header.DataCrc then
    Exit(False);

  // Обчислення CRC32 перших 7 полів заголовка (все до HdrCrc)
  CalcHdrCRC := crc32(0, @Block.Header, SizeOf(TNVRAMBlockHeader) - SizeOf(DWord));

  Result := (CalcHdrCRC = Block.Header.HdrCrc) and (Block.Magic = NVRAM_BLOCK_MAGIC);
end;

end.
