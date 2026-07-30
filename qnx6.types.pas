unit qnx6.types;

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  {$IFDEF USEGENERICS}
  Generics.Collections;
  {$ELSE}
  lgQueue,
  LGHashMap;
  {$ENDIF}

  // Підключаємо константи та ВСІ базові структури QNX6
  {$include './qnx_consts.inc'}

type
  TDwordArray = array of dword;

  TLevelData = record
    Count: dword;
    Data: TDwordArray;
  end;

  TBlocksList = record
    top: dword;
    level: array[0..2] of TLevelData;
  end;


type
  TQNX6FS_INO_CKSUM = (NONE = 0,  (* don't checksum inodes (default) *)
    CRC32 = 1,  (* POSIX CRC32 checksum in inodes  *)
    F32 = 2  (* Fletcher-32 checksum in inodes  *)
    );

  PQNX6_RawDirEntry = ^TQNX6_RawDirEntry;

  TQNX6_RawDirEntry = packed record
    inode: dword;
    len: byte;
    Data: array[0..QNX6FS_DIR_SHORT_LEN - 1] of byte;
  end;
  TQNX6_ARawDirEntry = array of TQNX6_RawDirEntry;

  PQNX6_ShortNameEntry = ^TQNX6_ShortNameEntry;

  TQNX6_ShortNameEntry = packed record
    Name: array[0..QNX6FS_DIR_SHORT_LEN - 1] of UTF8Char;
  end;

  PQNX6_LongNameEntry = ^TQNX6_LongNameEntry;

  TQNX6_LongNameEntry = packed record
    dummy1: array[0..2] of byte;
    blkno: dword;
    cksum: dword;
    dummy2: array[0..15] of byte;
  end;

  PQNX6_CryptNameEntry = ^TQNX6_CryptNameEntry;

  TQNX6_CryptNameEntry = packed record
    iscrypt: bytebool;
    dummy1: array[0..2] of byte;
    blkno: dword;
    cksum: dword;
    Name: array[0..15] of byte;
  end;


type
  TQNX6_DB = array[0..QNX6FS_DIRECT_BLKS - 1] of dword;

  TQNX6_IInode = packed record
    size: qword;
    blocks: TQNX6_DB;
    indirect: byte;
    flags: byte;
    dummy: array[0..5] of byte;
  end;

  TQNX6_LongName = packed record
    len: word;
    Name: array[0..QNX6FS_NAME_MAX - 1] of UTF8Char;
  end;

  PQNX6_DInode = ^TQNX6_DInode;

  TQNX6_DInode = packed record
    size: qword;
    uid: dword;
    gid: dword;
    ftime: dword;
    mtime: dword;
    atime: dword;
    ctime: dword;
    mode: word;
    nlink: word;
    blocks: TQNX6_DB;
    indirect: byte;
    flags: byte;
    dummy1: array[0..1] of byte;
    crypt: dword;
    emode: dword;
    acl_iextra_plus_one: dword;
    (* One-greater than the iextra index where the ACL record starts.     *)
    (* Encoded this way so that QNX6FS_IE_INVALID_INDEX is stored as zero *)
    (* for backward compatibility with existing records that have no ACL. *)
    generation: dword;  (* inode generation (inode reuse bumps it up). *)
    dummy2: array[0..3] of byte;
    cksum32: dword;     (* 32-bit inode checksum *)
  end;

  PQNX6_SuperBlockRaw = ^TQNX6_SuperBlockRaw;

  TQNX6_SuperBlockRaw = packed record
    Magic: dword;
    CRC: dword;
    Serial: qword;
    ctime: dword;
    atime: dword;
    flags: dword;
    version: word;
    rsrvblks: word;
    volumeid: TGuid;
    blocksize: dword;
    num_inodes: dword;
    free_inodes: dword;
    num_blocks: dword;
    free_blocks: dword;
    allocgroup: dword;
    inodes: TQNX6_IInode;
    bitmap: TQNX6_IInode;
    lnames: TQNX6_IInode;
    s_iclaim: TQNX6_IInode;
    s_iextra: TQNX6_IInode;
    migrate_blocks: dword;
    scrub_block: dword;
    nsparse: dword;
    ino_cksum: byte; // TQNX6FS_INO_CKSUM
    dummy: array[0..26] of byte;
  end;

  TQNX6_Keylist = packed record
    version: dword;
    key: array[0..QNX6FS_DOMAIN_MAX] of dword;
  end;

  TQNX6_Domainkey = packed record
    random: array [0..QNX6FS_IEXTRA_SALT_SIZE - 1] of byte;
    version: dword;
    signature: dword;
    keyno: byte;
    reserved1: byte;
    reserved2: word;
    dummy: array [0..50 - 1] of byte;
    keytype: byte;
    keylen: byte;
    key: array [0..QNX6FS_IEXTRA_MAX_KEY_SIZE - 1] of byte;
  end;

  TQNX6_Filekey = packed record
    random: array [0..QNX6FS_IEXTRA_SALT_SIZE - 1] of byte;
    version: dword;
    flags: word;
    mode: word;
    size: qword;
    ino: qword;
    uid: dword;
    gid: dword;
    migration: qword;
    dummy: array[0..22 - 1] of byte;
    keytype: byte;
    keylen: byte;
    key: array [0..QNX6FS_IEXTRA_MAX_KEY_SIZE - 1] of byte;
  end;

  {$IFDEF USEGENERICS}
  TFreeBlocks     = specialize TQueue<dword>;
  TDInodeMap      = specialize TDictionary<dword, TQNX6_DInode>;
  TDInodeMapEntry = specialize TPair<dword, TQNX6_DInode>;
  {$ELSE}
  TFreeBlocksType = specialize TGQueue<dword>;
  TFreeBlocks = TFreeBlocksType;

  // Точно як у вашому оригіналі:
  // TGLiteHashMapLP<KeyType, ValueType, KeyTypeForDefaultHasher>
  TDInodeMapType = specialize TGLiteHashMapLP<dword, TQNX6_DInode, dword>;

  TDInodeMap = TDInodeMapType.TMap;
  TDInodeMapEntry = TDInodeMapType.TEntry;
  {$ENDIF}


implementation

end.
