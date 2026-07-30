procedure SetShortDirEntryName(var Entry: TQNX6_RawDirEntry; const AName: utf8string);

procedure SetShortDirEntryName(var Entry: TQNX6_RawDirEntry; const AName: utf8string);
var
  Len: integer;
begin
  Len := Length(AName);
  if Len > QNX6FS_DIR_SHORT_LEN then
    raise EArgumentException.CreateFmt('Name "%s" exceeds short dir entry capacity', [AName]);

  Entry.len := byte(Len);
  FillChar(Entry.Data[0], SizeOf(Entry.Data), 0);
  if Len > 0 then
    Move(AName[1], Entry.Data[0], Len);
end;


procedure CreateMockDevice(FMemoryStream: TMemoryStream; ABlockSize, ATotalBlocks: integer);

procedure CreateMockDevice(FMemoryStream: TMemoryStream; ABlockSize, ATotalBlocks: integer);
var
  i, InodesCount, r1, r2, r3, r4: integer;
  FirstDataBlock: DWord;
  RawSB: TQNX6_SuperBlockRaw;
  RInode, BInode: TQNX6_DInode;
  RootBlockNo, BootBlockNo: DWord;
  InodesBlockNo, BitmapBlockNo: DWord;
  DataBuf: TBytes;
  RootEntries, BootEntries: array[0..1] of TQNX6_RawDirEntry;
  BootSectPlaceholder: array[0..511] of byte;
  BasePtr: pbyte;

  // --- Відсутні змінні, які були додані ---
  BlockSize: integer;
  PtrsInBlock: integer;
  MaxBlocks: int64;
  DataStart: int64;
  Sys0AreaStart: int64;
  Sys1AreaStart: int64;
  UserAreaStart: int64;

  procedure WriteBlockViaStream(ABlkNo: DWord; const ABuffer; ASize: integer);
  var
    TargetOffset: int64;
  begin
    TargetOffset := DataStart + int64(ABlkNo) * ABlockSize;
    FMemoryStream.Position := TargetOffset;
    FMemoryStream.WriteBuffer(ABuffer, ASize);
  end;

begin
  if (ABlockSize mod 512) <> 0 then
    raise EArgumentException.Create('BlockSize must be a multiple of 512');

  // 1. Ініціалізація пам'яті під віртуальний диск
  FMemoryStream.Size := QWord(ABlockSize) * ATotalBlocks;

  // 2. Встановлення геометрії пристрою
  BlockSize := ABlockSize;
  PtrsInBlock := ABlockSize div SizeOf(DWord);
  MaxBlocks := QNX6FS_DIRECT_BLKS * PtrsInBlock * PtrsInBlock;

  InodesCount := 256;

  // 3. Запис Boot-сектора (абсолютна позиція 0)
  FillChar(BootSectPlaceholder[0], SizeOf(BootSectPlaceholder), 0);
  PDWord(@BootSectPlaceholder[0])^ := QNX_BOOT_MAGIC;
  PDWord(@BootSectPlaceholder[8])^ := 8;
  PDWord(@BootSectPlaceholder[12])^ := ATotalBlocks * ABlockSize;

  if BlockSize <= 4096 then
    DataStart := QNX6FS_BOOT_RSRV + QNX6FS_SBLK_RSRV
  else
    DataStart := QNX6FS_BOOT_RSRV + QNX6FS_SBLK_RSRV + Abs(QNX6FS_BOOT_RSRV + QNX6FS_SBLK_RSRV - BlockSize);

  FirstDataBlock := iceil(DataStart, BlockSize);

  // 4. Розрахунок системних областей
  r1 := InodesCount * SizeOf(TQNX6_DInode);
  r2 := iceil(r1, BlockSize);               // Блоків під іноди
  r3 := iceil(ATotalBlocks, 8);              // Розмір бітмапа в байтах
  r4 := iceil(r3, BlockSize);               // Блоків під бітмап

  Sys0AreaStart := 0;
  Sys1AreaStart := (r2 + iceil(r2, PtrsInBlock) + r4 + iceil(r4, PtrsInBlock));
  UserAreaStart := 2 * Sys1AreaStart;

  // 5. Адресація системних блоків (абсолютні номери блоків від початку диска)
  InodesBlockNo := FirstDataBlock;
  BitmapBlockNo := InodesBlockNo + r2;
  RootBlockNo := BitmapBlockNo + r4;
  BootBlockNo := RootBlockNo + 1;

  // 6. Формування інодів для / та /boot
  RInode := Default(TQNX6_DInode);
  RInode.size := BlockSize;
  FillDWord(RInode.blocks, 16, $FFFFFFFF);
  RInode.mode := &777 or S_IFDIR;
  RInode.nlink := 3;
  RInode.blocks[0] := RootBlockNo;

  BInode := Default(TQNX6_DInode);
  BInode.size := BlockSize;
  FillDWord(BInode.blocks, 16, $FFFFFFFF);
  BInode.mode := &744 or S_IFDIR;
  BInode.nlink := 2;
  BInode.blocks[0] := BootBlockNo;

  // 7. Запис каталогів прямо у буфер пам'яті
  SetLength(DataBuf, BlockSize);

  // /boot
  FillChar(BootEntries, SizeOf(BootEntries), 0);
  BootEntries[0].inode := 2;
  SetShortDirEntryName(BootEntries[0], '.');
  BootEntries[1].inode := 1;
  SetShortDirEntryName(BootEntries[1], '..');

  FillChar(DataBuf[0], BlockSize, 0);
  Move(BootEntries[0], DataBuf[0], SizeOf(BootEntries));
  WriteBlockViaStream(BootBlockNo, DataBuf, BlockSize);

  // /
  FillChar(RootEntries, SizeOf(RootEntries), 0);
  RootEntries[0].inode := 1;
  SetShortDirEntryName(RootEntries[0], '.');
  RootEntries[1].inode := 2;
  SetShortDirEntryName(RootEntries[1], 'boot');

  FillChar(DataBuf[0], BlockSize, 0);
  Move(RootEntries[0], DataBuf[0], SizeOf(RootEntries));
  WriteBlockViaStream(RootBlockNo, DataBuf, BlockSize);

  // Inodes
  FillChar(DataBuf[0], BlockSize, $FF);
  Move(RInode, DataBuf[0], SizeOf(TQNX6_DInode));
  Move(BInode, DataBuf[SizeOf(TQNX6_DInode)], SizeOf(TQNX6_DInode));

  FillChar(DataBuf[0], BlockSize, $FF);
  for i := 1 to r2 do
    WriteBlockViaStream(InodesBlockNo + i, DataBuf, BlockSize);

  // 8. Підготовка SuperBlock
  FillChar(RawSB, SizeOf(TQNX6_SuperBlockRaw), 0);
  RawSB.Magic := QNX6FS_SIGNATURE2;
  CreateGUID(RawSB.volumeid);
  RawSB.Serial := 1;
  RawSB.version := QNX6FS_FSYS_VERSION;
  RawSB.rsrvblks := QNX6FS_DEFAULT_RSRV;
  RawSB.blocksize := ABlockSize;
  RawSB.num_inodes := InodesCount;
  RawSB.free_inodes := InodesCount - 2;
  RawSB.allocgroup := 16;
  RawSB.num_blocks := ATotalBlocks;
  RawSB.free_blocks := ATotalBlocks - (BootBlockNo + 1);
  RawSB.flags := 0;

  RawSB.lnames.size := 0;
  FillDWord(RawSB.lnames.blocks, 16, $FFFFFFFF);

  RawSB.inodes.size := r1;
  RawSB.inodes.indirect := 0;
  FillDWord(RawSB.inodes.blocks, 16, $FFFFFFFF);
  RawSB.inodes.blocks[0] := InodesBlockNo;

  RawSB.bitmap.size := r3;
  RawSB.bitmap.indirect := 0;
  FillDWord(RawSB.bitmap.blocks, 16, $FFFFFFFF);
  RawSB.bitmap.blocks[0] := BitmapBlockNo;
  RawSB.CRC := CRC32_QNX(@RawSB.Serial, 512 - 8);

  FMemoryStream.Position := 0;
  FMemoryStream.WriteBuffer(BootSectPlaceholder[0], SizeOf(BootSectPlaceholder));

  // 9. Прямий запис SuperBlock за стандартною адресою $2000 (8192)
  FMemoryStream.Position := $2000;
  FMemoryStream.WriteBuffer(RawSB, SizeOf(RawSB));

  FMemoryStream.Position := 0;
  FMemoryStream.SaveToFile('dummy.qnx6');
end;

