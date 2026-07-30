unit qnx6.blockmgr.tests;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  qnx6.blockmgr, qnx6.device, qnx6.types;

type
  { TQNX6VolumeDeviceMock }
  // Спеціальний Mock-пристрій для тестування у пам'яті
  TQNX6VolumeDeviceMock = class(TQNX6VolumeDevice)
  private
    FMemoryStream: TMemoryStream;
  public
    constructor CreateMock(ABlockSize: DWord = 512; ATotalBlocks: DWord = 1000);
    destructor Destroy; override;

    procedure ReadBlock(BlockNo: DWord; Buffer: Pointer; Size: DWord = 0);
    procedure WriteBlock(BlockNo: DWord; Buffer: Pointer; Size: DWord = 0);
  end;

  { TestTQNX6BlockManager }

  TestTQNX6BlockManager = class(TTestCase)
  private
    FDevice: TQNX6VolumeDeviceMock;
    FBlockMgr: TQNX6BlockManager;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestAllocateBlocksBasic;
    procedure TestFreeBlocks;
    procedure TestAddBlockToChain;
    procedure TestRemoveBlockFromChain;
    procedure TestTransitionToIndirectLevel;
  end;

implementation

uses uMisc;

  { TQNX6VolumeDeviceMock }

constructor TQNX6VolumeDeviceMock.CreateMock(ABlockSize: DWord = 512; ATotalBlocks: DWord = 1000);
begin
  FMemoryStream := TMemoryStream.Create;
  CreateMockDevice(FMemoryStream, ABlockSize, ATotalBlocks);

  inherited Create(FMemoryStream);
  Open;
end;

destructor TQNX6VolumeDeviceMock.Destroy;
begin
  inherited Destroy;
  FreeAndNil(FMemoryStream);
end;

procedure TQNX6VolumeDeviceMock.ReadBlock(BlockNo: DWord; Buffer: Pointer; Size: DWord);
var
  ReadSize: DWord;
begin
  if Size = 0 then ReadSize := BlockSize
  else
    ReadSize := Size;
  FMemoryStream.Position := QWord(BlockNo) * BlockSize;
  FMemoryStream.ReadBuffer(Buffer^, ReadSize);
end;

procedure TQNX6VolumeDeviceMock.WriteBlock(BlockNo: DWord; Buffer: Pointer; Size: DWord);
var
  WriteSize: DWord;
begin
  if Size = 0 then WriteSize := BlockSize
  else
    WriteSize := Size;
  FMemoryStream.Position := QWord(BlockNo) * BlockSize;
  FMemoryStream.WriteBuffer(Buffer^, WriteSize);
end;

{ TestTQNX6BlockManager }

procedure TestTQNX6BlockManager.SetUp;
begin
  inherited SetUp;
  // Створюємо Mock-пристрій на 1000 блоків по 512 байт
  FDevice := TQNX6VolumeDeviceMock.CreateMock(4096, $100);
  FBlockMgr := TQNX6BlockManager.Create(FDevice);
  FBlockMgr.LoadBitmap;
end;

procedure TestTQNX6BlockManager.TearDown;
begin
  FreeAndNil(FBlockMgr);
  FreeAndNil(FDevice);
  inherited TearDown;
end;

procedure TestTQNX6BlockManager.TestAllocateBlocksBasic;
var
  Allocated: TDwordArray;
begin
  Allocated := FBlockMgr.AllocateBlocks(3, False);

  AssertEquals('Має виділитися рівно 3 блоки', 3, Length(Allocated));
  AssertTrue('Перший блок має виділятися з UserAreaStart (>=10)',
    Allocated[0] >= FDevice.UserAreaStart);
  AssertTrue('Виділений блок має відмічатися у бітмапі',
    FBlockMgr.Bitmap.Get(Allocated[0]));
  AssertTrue('Прапорець IsChanged має встановитися в True', FBlockMgr.IsChanged);
end;

procedure TestTQNX6BlockManager.TestFreeBlocks;
var
  Allocated: TDwordArray;
  FreeCountBefore, FreeCountAfter: DWord;
begin
  Allocated := FBlockMgr.AllocateBlocks(2, False);
  FreeCountBefore := FDevice.ActiveSB.FreeBlocks;

  FBlockMgr.FreeBlocks(Allocated);
  FreeCountAfter := FDevice.ActiveSB.FreeBlocks;

  AssertEquals('Кількість вільних блоків має збільшитися на 2',
    FreeCountBefore + 2, FreeCountAfter);
  AssertFalse('Блок має стати знову вільним у бітмапі',
    FBlockMgr.Bitmap.Get(Allocated[0]));
end;

procedure TestTQNX6BlockManager.TestAddBlockToChain;
var
  Blocks: TBlocksList;
  NewBlk: DWord;
  i: integer;
begin
  Blocks.top := 0;
  for i := 0 to 2 do
  begin
    Blocks.level[i].Count := 0;
    SetLength(Blocks.level[i].Data, 0);
  end;

  NewBlk := FBlockMgr.AddBlockToChain(Blocks);

  AssertFalse('Номер блоку не повинен бути 0 у разі успіху', NewBlk = 0);
  AssertEquals('У level[0] має з''явитися 1 блок даних', 1, Blocks.level[0].Count);
  AssertEquals('Номер блоку в level[0] має збігатися з поверненим',
    NewBlk, Blocks.level[0].Data[0]);
  AssertEquals('Рівень дерева має залишатися 0', 0, Blocks.top);
end;

procedure TestTQNX6BlockManager.TestTransitionToIndirectLevel;
var
  Blocks: TBlocksList;
  i: integer;
begin
  Blocks.top := 0;
  for i := 0 to 2 do
  begin
    Blocks.level[i].Count := 0;
    SetLength(Blocks.level[i].Data, 0);
  end;

  // Додаємо 17 блоків (на 1 більше ніж QNX6FS_DIRECT_BLKS = 16)
  for i := 1 to QNX6FS_DIRECT_BLKS + 1 do
    FBlockMgr.AddBlockToChain(Blocks);

  AssertEquals('У level[0] має бути 17 блоків даних', QNX6FS_DIRECT_BLKS +
    1, Blocks.level[0].Count);
  AssertEquals('Рівень дерева має піднятися до 1 (Indirect)', 1, Blocks.top);
  AssertEquals('В level[1] має з''явитися 1 індексний блок',
    1, Blocks.level[1].Count);
end;

procedure TestTQNX6BlockManager.TestRemoveBlockFromChain;
var
  Blocks: TBlocksList;
  AddedBlk: DWord;
  FreedArray: TDwordArray;
  i: integer;
begin
  Blocks.top := 0;
  for i := 0 to 2 do
  begin
    Blocks.level[i].Count := 0;
    SetLength(Blocks.level[i].Data, 0);
  end;

  AddedBlk := FBlockMgr.AddBlockToChain(Blocks);
  FreedArray := FBlockMgr.RemoveBlockFromChain(Blocks, AddedBlk);

  AssertEquals('Має повернутися 1 блок для звільнення',
    1, Length(FreedArray));
  AssertEquals('Повернутий блок має збігатися з видаленим',
    AddedBlk, FreedArray[0]);
  AssertEquals('Кількість блоків у level[0] має стати 0', 0, Blocks.level[0].Count);
end;

initialization
  RegisterTest(TestTQNX6BlockManager);
end.
