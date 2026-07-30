unit qnx6.device.tests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  qnx6.device, qnx6.types;

type
  { TTestQNX6Device }

  TTestQNX6Device = class(TTestCase)
  private
    FStream: TMemoryStream;
    FDevice: TQNX6VolumeDevice;
    procedure CreateMockFS(BlockSize: DWord; NumBlocks: DWord);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestBootBlockReadWrite;
    procedure TestSuperBlockValidation;
    procedure TestReadWriteBlockInMemoryCache;
    procedure TestFlushChangesToStream;
    procedure TestOutOfBoundsRead;
  end;

implementation

uses uMisc;
  { TTestQNX6Device }

procedure TTestQNX6Device.SetUp;
begin
  inherited SetUp;
  FStream := TMemoryStream.Create;
end;

procedure TTestQNX6Device.TearDown;
begin
  FreeAndNil(FDevice);
  FreeAndNil(FStream);
  inherited TearDown;
end;

// Допоміжний метод для створення "фейкового" образу QNX6 у пам'яті
procedure TTestQNX6Device.CreateMockFS(BlockSize: DWord; NumBlocks: DWord);
begin
  CreateMockDevice(FStream, BlockSize, NumBlocks);
end;

procedure TTestQNX6Device.TestBootBlockReadWrite;
var
  BB: TQNX6_BootBlock;
begin
  FStream.SetSize(1024);

  // Тест створення та запису BootBlock
  BB := TQNX6_BootBlock.Create(FStream);
  try
    BB.off_qnx6fs := $1000;
    BB.Subtype := 8;
    BB.Size := $20000;
    BB.Write; // Запис у потік
  finally
    BB.Free;
  end;

  // Тест зчитування записаного BootBlock
  FStream.Position := 0;
  BB := TQNX6_BootBlock.Create(FStream);
  try
    CheckTrue(BB.isValid, 'BootBlock має бути валідним');
    CheckEquals(DWord($1000), BB.off_qnx6fs, 'off_qnx6fs розбігається');
    CheckEquals(DWord(8), BB.Subtype, 'Subtype розбігається');
  finally
    BB.Free;
  end;
end;

procedure TTestQNX6Device.TestSuperBlockValidation;
var
  SB: TQNX6_SuperBlock;
begin
  CreateMockFS(1024, 100);
  SB := TQNX6_SuperBlock.Create(FStream);
  try
    SB.SelfPos := $2000;
    SB.Read;
    CheckTrue(SB.isValid, 'Суперблок з правильним CRC має бути валідним');

    // Псуємо CRC і перевіряємо
    SB.CRC := $DEADBEEF;
    CheckFalse(SB.isValid,
      'Суперблок із зіпсованим CRC НЕ має бути валідним');
  finally
    SB.Free;
  end;
end;

procedure TTestQNX6Device.TestReadWriteBlockInMemoryCache;
const
  textBlockSize = 4096;
var
  WriteBuf, ReadBuf: array[0..textBlockSize - 1] of byte;
  i: integer;
begin
  CreateMockFS(textBlockSize, $100);
  FDevice := TQNX6VolumeDevice.Create(FStream);
  FDevice.Open;

  // Готуємо дані для тесту
  for i := 0 to textBlockSize - 1 do WriteBuf[i] := byte(i mod 256);
  FillChar(ReadBuf, SizeOf(ReadBuf), 0);

  // Пишемо блок (має потрапити в кеш FChangedBlocks, а не в потік)
  FDevice.WriteBlock(5, @WriteBuf[0]);

  // Читаємо блок (має прочитатися з кешу FChangedBlocks)
  FDevice.ReadBlock(5, @ReadBuf[0]);

  CheckEquals(True, CompareMem(@WriteBuf[0], @ReadBuf[0], textBlockSize),
    'Зчитані дані з кешу повинні збігатися з записаними');
end;

procedure TTestQNX6Device.TestFlushChangesToStream;
var
  WriteBuf, ReadBuf: array[0..511] of byte;
  DataOffset: int64;
  i: integer;
begin
  CreateMockFS(512, 50);
  FDevice := TQNX6VolumeDevice.Create(FStream);
  FDevice.Open;

  for i := 0 to 511 do WriteBuf[i] := $AA;

  // Записуємо в кеш і скидаємо на "диск"
  FDevice.WriteBlock(2, @WriteBuf[0]);
  FDevice.Flush;

  CheckEquals(0, FDevice.ChangedBlocks.Count,
    'Після Flush мапа кешу має бути порожньою');

  // Перевіряємо, чи фізично зміни потрапили в TStream
  DataOffset := FDevice.DataStart + (2 * 512);
  FStream.Position := DataOffset;
  FStream.Read(ReadBuf, 512);

  CheckEquals(True, CompareMem(@WriteBuf[0], @ReadBuf[0], 512),
    'Дані у потоці TStream повинні бути оновлені після Flush');
end;

procedure TTestQNX6Device.TestOutOfBoundsRead;
var
  DummyBuf: array[0..511] of byte;
  ExceptionRaised: boolean;
begin
  CreateMockFS(512, 10); // Всього 10 блоків (індекси 0..9)
  FDevice := TQNX6VolumeDevice.Create(FStream);
  FDevice.Open;

  ExceptionRaised := False;
  try
    // Пробуємо прочитати 99-й блок (поза межами)
    FDevice.ReadBlock(99, @DummyBuf[0]);
  except
    on E: Exception do
      ExceptionRaised := True;
  end;

  CheckTrue(ExceptionRaised,
    'Спроба читання за межами NumBlocks повинна викликати Exception');
end;

initialization
  // Реєструємо тест у глобальному реєстрі FPCUnit
  RegisterTest(TTestQNX6Device);
end.
