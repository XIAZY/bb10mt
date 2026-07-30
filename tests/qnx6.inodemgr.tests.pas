unit qnx6.inodemgr.tests;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  qnx6.types, qnx6.device, qnx6.blockmgr, qnx6.inodemgr;

type

  { TTestQNX6InodeManager }

  TTestQNX6InodeManager = class(TTestCase)
  private
    FStream: TMemoryStream;
    FDevice: TQNX6VolumeDevice;
    FBlockMgr: TQNX6BlockManager;
    FManager: TQNX6InodeManager;

    procedure InitFakeFS;
    procedure CallGetZeroInode;
    procedure CallGetOutOfRangeInode;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestCreateInode;
    procedure TestEraseInode;
    procedure TestGetSetInodeValidation;
  end;

implementation

procedure TTestQNX6InodeManager.InitFakeFS;
begin

  FDevice := TQNX6VolumeDevice.Create(FStream);
  CreateMockDevice(FStream, 4096, $100);
  FDevice.Open;

  FBlockMgr := TQNX6BlockManager.Create(FDevice);
  FManager := TQNX6InodeManager.Create(FDevice, FBlockMgr);
  FBlockMgr.LoadBitmap;
  FManager.LoadInodes(true);
  FManager.LoadLongNames;

end;

procedure TTestQNX6InodeManager.SetUp;
begin
  inherited SetUp;
  FStream := TMemoryStream.Create;
  InitFakeFS;
end;

procedure TTestQNX6InodeManager.TearDown;
begin
  FreeAndNil(FManager);
  FreeAndNil(FBlockMgr);
  FreeAndNil(FDevice);
  FreeAndNil(FStream);
  inherited TearDown;
end;

procedure TTestQNX6InodeManager.CallGetZeroInode;
begin
  FManager.GetInode(0);
end;

procedure TTestQNX6InodeManager.CallGetOutOfRangeInode;
begin
  FManager.GetInode(FDevice.ActiveSB.RawData.num_inodes + 100);
end;

procedure TTestQNX6InodeManager.TestCreateInode;
var
  NewIdx: DWord;
  Inode: TQNX6_DInode;
  InitialFree: DWord;
begin
  InitialFree := FDevice.ActiveSB.RawData.free_inodes;

  NewIdx := FManager.CreateInode($1ED);

  AssertEquals('Новий Inode має мати валідний індекс >= 2', True, NewIdx >= 2);
  AssertEquals('Кількість вільних інодів має зменшитися на 1',
    InitialFree - 1, FDevice.ActiveSB.RawData.free_inodes);

  Inode := FManager.GetInode(NewIdx);
  AssertEquals('Режим (mode) має відповідати переданому', $1ED, Inode.mode);
  AssertEquals('Кількість посилань nlink має бути 1', 1, Inode.nlink);
end;

procedure TTestQNX6InodeManager.TestEraseInode;
var
  Idx: DWord;
begin
  Idx := FManager.CreateInode($1ED);
  AssertTrue('Inode має бути позначений як використаний',
    FManager.InodeUsed(Idx));

  FManager.EraseInode(Idx);

  AssertFalse('Inode має стати вільним після EraseInode', FManager.InodeUsed(Idx));
end;

procedure TTestQNX6InodeManager.TestGetSetInodeValidation;
begin
  AssertException('Має бути помилка при запиті Inode = 0',
    Exception, @CallGetZeroInode);

  AssertException('Має бути помилка при запиті Inode > NumInodes',
    Exception, @CallGetOutOfRangeInode);
end;

initialization
  RegisterTest(TTestQNX6InodeManager);
end.
