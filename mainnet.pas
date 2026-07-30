unit MainNet;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, blcksock, synsock,
  synautil, mormot.crypt.core,
  mormot.crypt.rsa,
  mormot.core.base, mormot.core.os, Logger;

const
  KEEPALIVE_INTERVAL = 5000; // ms

  // Connection States
  DISCONNECTED = 0;
  CONNECTING = 1;
  NEGOTIATED = 2;
  AUTHORISED = 3;
  AUTHENTICATED = 4;
  SSH_ACCEPTED = 5;
  COMPLETE = 6;

  CHALLENGE_ITEM_PIN = 1;
  CHALLENGE_ITEM_SESSIONKEY = 2;
  CHALLENGE_ITEM_BSN = 3;
  CHALLENGE_ITEM_PERMISSION = 4;

type
  TMainNet = class;

  TSocketThread = class(TThread)
  private
    FMainNet: TMainNet;
  protected
    procedure Execute; override;
  public
    constructor Create(AMainNet: TMainNet);
  end;

  TMainNet = class(TObject)
  private
    FSocket: TTCPBlockSocket;
    FSocketThread: TSocketThread;

    FPassword: string;
    FWrongPass: boolean;
    FIP: string;
    FState: integer;
    FConnState: integer;
    FLastKeepAlive: int64;
    FBBExists: boolean;
    FKeyExists: boolean;
    FLoggedIn: boolean;
    FWifiLoggedIn: boolean;
    FRestoring: boolean;
    FSSHKey: string;
    FLog: TLogManager;

    // Challenge response data
    FSessionKey: TBytes;
    FPrivKey: TRsaPrivateKey;
    FHashedPassword: rawbytestring;

    procedure LogMsg(const Msg: string);
    procedure AESEncryptSend(const Plain: TBytes; Code: word);
    procedure DoKeepAlive;
    procedure KeepAlive;
    procedure SocketLoop;
    procedure RequestConfigure;
    procedure RequestChallenge;
    procedure ReplyChallenge(const ServerChallenge: rawbytestring);
    procedure RequestAuthenticate;
    procedure StartServices;
    procedure Authorise(const Data: TBytes);
    procedure SendSSHKey;
    procedure OnSocketConnect;
    procedure OnSocketDisconnect;
    procedure OnSocketRead(const Data: TBytes; ASize: integer);
    procedure ProcessServerChallenge(const Data: TBytes);
  public
    constructor Create(Log: TLogManager = nil);
    destructor Destroy; override;

    procedure Init;
    procedure TargetClose;
    procedure EndConnection;

    property Password: string read FPassword write FPassword;
    property WrongPass: boolean read FWrongPass write FWrongPass;
    property IP: string read FIP write FIP;
    property SSHKey: string read FSSHKey write FSSHKey;
    property State: integer read FState write FState;
    property Detail: integer read FConnState;
    property BBExists: boolean read FBBExists write FBBExists;
    property KeyExists: boolean read FKeyExists write FKeyExists;
  end;

implementation

uses uCrypto;

  {------------------ TSocketThread ------------------}

constructor TSocketThread.Create(AMainNet: TMainNet);
begin
  inherited Create(False);
  FreeOnTerminate := False;
  FMainNet := AMainNet;
end;

procedure TSocketThread.Execute;
begin
  if Assigned(FMainNet) then
    FMainNet.SocketLoop;
end;

type
  TTargetCode = (
    tcHello = 1,
    tcFeedback = 2,
    tcStartRequest = 3,
    tcEncryptedChallengeResponse = 4,
    tcDecryptedChallengeResponse = 5,
    tcKeepAlive = 6,
    tcSendSSHKey = 7,
    tcAuthenticateChallengeRequest = 8,
    tcAuthenticateChallengeResponse = 9,
    tcAuthenticate = 10,
    tcStartServices = 11,
    tcClose = 12
    );

  TTargetFeedback = (
    tfResponseOK = 0,
    tfUnexpectedCommand = 1,
    tfChallengeFailure = 2,
    tfVersionMismatch = 10,
    tfNoPasswordRequired = 17
    );

  {------------------ TMainNet ------------------}

constructor TMainNet.Create(Log: TLogManager = nil);
begin
  inherited Create;
  FSocket := TTCPBlockSocket.Create;
  FState := 0;
  FConnState := DISCONNECTED;
  FRestoring := False;
  FLoggedIn := False;
  FLog := Log;
  FWifiLoggedIn := False;
  FBBExists := False;
  FKeyExists := False;
  FSocketThread := nil;
  FLastKeepAlive := GetTickCount64();
end;

destructor TMainNet.Destroy;
begin
  EndConnection;
  FSocket.Free;
  inherited Destroy;
end;

procedure TMainNet.LogMsg(const Msg: string);
begin
  if Assigned(FLog) then
    FLog.AddMessage(Msg);
end;

procedure TMainNet.Init;
begin
  FState := 1;
  FConnState := CONNECTING;
  LogMsg(Format('Connecting to target %s:4455', [FIP]));

  FSocket.Connect(FIP, '4455');
  if FSocket.LastError = 0 then
  begin
    OnSocketConnect;
    FSocketThread := TSocketThread.Create(Self);
  end
  else
  begin
    LogMsg('Connection failed: ' + FSocket.LastErrorDesc);
    FState := 0;
    FConnState := DISCONNECTED;
  end;
end;

procedure TMainNet.EndConnection;
begin
  FState := 0;
  FConnState := DISCONNECTED;

  // Спочатку закриваємо сокет, щоб розблокувати RecvBuffer / CanRead у потоці
  if Assigned(FSocket) then
  begin
    TargetClose;
    FSocket.CloseSocket;
  end;

  if Assigned(FSocketThread) then
  begin
    FSocketThread.Terminate;
    FSocketThread.WaitFor;
    FreeAndNil(FSocketThread);
  end;
end;

procedure TMainNet.SocketLoop;
var
  Data: TBytes;
  BytesRead: integer;
begin
  SetLength(Data, 4096);
  while (FState > 0) and Assigned(FSocketThread) and not FSocketThread.Terminated do
  begin
    if FSocket.CanRead(200) then
    begin
      BytesRead := FSocket.RecvBuffer(@Data[0], Length(Data));
      if BytesRead > 0 then
        OnSocketRead(Data, BytesRead)
      else if FSocket.LastError <> 0 then
      begin
        OnSocketDisconnect;
        Break;
      end;
    end;

    DoKeepAlive;
    Sleep(10);
  end;
end;

procedure TMainNet.DoKeepAlive;
var
  NowTime: QWord;
begin
  NowTime := GetTickCount64();
  if (FConnState >= COMPLETE) and ((NowTime - FLastKeepAlive) >= KEEPALIVE_INTERVAL) then
  begin
    KeepAlive;
    FLastKeepAlive := NowTime;
  end;
end;

procedure TMainNet.OnSocketConnect;
begin
  if FState > 0 then
    RequestConfigure
  else
    FBBExists := True;
end;

procedure TMainNet.OnSocketDisconnect;
begin
  FState := 0;
  FConnState := DISCONNECTED;
  LogMsg('Socket disconnected.');
end;

procedure TMainNet.SendSSHKey;
var
  KeyLen: word;
  Packet: TBytes;
begin
  LogMsg('Successfully authenticated with target credentials.');
  LogMsg('Sending SSH key to target');

  KeyLen := Length(FSSHKey);
  if KeyLen = 0 then Exit;

  SetLength(Packet, 2 + KeyLen);
  PWord(@Packet[0])^ := NtoBE(KeyLen);
  Move(PChar(FSSHKey)^, Packet[2], KeyLen);

  AESEncryptSend(Packet, Ord(tcSendSSHKey));
end;

procedure TMainNet.ProcessServerChallenge(const Data: TBytes);
var
  SourceLength, ContainerLength: word;
  EncryptedBlob: TBytes;
  ServerChallenge: rawbytestring;
  RSA: TRsa;
begin
  LogMsg(Format('Authenticating with target %s:4455', [FIP]));

  if Length(Data) < 30 then Exit;

  SourceLength := LEtoN(PWord(@Data[10])^);
  ContainerLength := LEtoN(PWord(@Data[16])^);

  if Length(Data) < (30 + SourceLength + ContainerLength) then
  begin
    LogMsg('Error: Invalid challenge payload length.');
    Exit;
  end;

  SetLength(EncryptedBlob, ContainerLength);
  if ContainerLength > 0 then
    Move(Data[30 + SourceLength], EncryptedBlob[0], ContainerLength);

  RSA := TRsa.Create;
  try
    RSA.LoadFromPrivateKey(FPrivKey);
    ServerChallenge := RSA.Pkcs1Decrypt(@EncryptedBlob[0]);
  finally
    RSA.Free;
  end;

  ReplyChallenge(ServerChallenge);
end;

procedure TMainNet.OnSocketRead(const Data: TBytes; ASize: integer);
var
  Code: word;
  FCode: TTargetFeedback;
  Len: word;
  Txt: string;
begin
  if ASize < 6 then Exit;

  Code := BEtoN(PWord(@Data[4])^);

  case TTargetCode(Code) of
    tcFeedback:
    begin
      if ASize < 10 then Exit;
      FCode := TTargetFeedback(BEtoN(PWord(@Data[6])^));
      Len := BEtoN(PWord(@Data[8])^);

      if (Len > 0) and (ASize >= 10 + Len) then
      begin
        SetLength(Txt, Len);
        Move(Data[10], PChar(Txt)^, Len);
      end;

      if (FCode = tfResponseOK) then
      begin
        if FConnState = CONNECTING then
        begin
          RequestChallenge;
          FConnState := NEGOTIATED;
        end
        else
        begin
          if FConnState > COMPLETE then Exit;
          if FConnState <> COMPLETE then
          begin
            Inc(FConnState);
            if FConnState = COMPLETE then
              LogMsg('Successfully connected. Connection established.');
          end;

          case FConnState of
            AUTHORISED: RequestAuthenticate;
            AUTHENTICATED: SendSSHKey;
            SSH_ACCEPTED: begin
              LogMsg('SSH key successfully transferred.');
              StartServices;
            end;
            COMPLETE: KeepAlive;
          end;
        end;
      end;
    end;

    tcEncryptedChallengeResponse:
      ProcessServerChallenge(Data);

    tcAuthenticateChallengeResponse:
      Authorise(Data);
  end;
end;

procedure TMainNet.RequestConfigure;
var
  Packet: array[0..5] of byte;
begin
  PWord(@Packet[0])^ := NtoBE(word(6));
  PWord(@Packet[2])^ := NtoBE(word(2));
  PWord(@Packet[4])^ := NtoBE(word(tcHello));
  FSocket.SendBuffer(@Packet[0], SizeOf(Packet));
end;

procedure TMainNet.RequestAuthenticate;
var
  Packet: array[0..5] of byte;
begin
  PWord(@Packet[0])^ := NtoBE(word(6));
  PWord(@Packet[2])^ := NtoBE(word(2));
  PWord(@Packet[4])^ := NtoBE(word(tcAuthenticateChallengeRequest));
  FSocket.SendBuffer(@Packet[0], SizeOf(Packet));
end;

procedure TMainNet.StartServices;
var
  Packet: array[0..5] of byte;
begin
  PWord(@Packet[0])^ := NtoBE(word(6));
  PWord(@Packet[2])^ := NtoBE(word(2));
  PWord(@Packet[4])^ := NtoBE(word(tcStartServices));
  FSocket.SendBuffer(@Packet[0], SizeOf(Packet));
end;

procedure TMainNet.KeepAlive;
var
  Packet: array[0..5] of byte;
begin
  PWord(@Packet[0])^ := NtoBE(word(6));
  PWord(@Packet[2])^ := NtoBE(word(2));
  PWord(@Packet[4])^ := NtoBE(word(tcKeepAlive));
  FSocket.SendBuffer(@Packet[0], SizeOf(Packet));
end;

procedure TMainNet.TargetClose;
var
  Packet: array[0..5] of byte;
begin
  PWord(@Packet[0])^ := NtoBE(word(6));
  PWord(@Packet[2])^ := NtoBE(word(2));
  PWord(@Packet[4])^ := NtoBE(word(tcClose));
  FSocket.SendBuffer(@Packet[0], SizeOf(Packet));
end;

procedure TMainNet.RequestChallenge;
var
  RSA: TRsa;
  PubKey: TRsaPublicKey;
  Packet: TBytes;
  ModLen: integer;
begin
  RSA := TRsa.Create;
  try
    RSA.Generate(1024);
    PubKey := RSA.SavePublicKey;
    ModLen := Length(PubKey.Modulus);

    if ModLen > 128 then
      raise Exception.Create('Modulus > 128 bytes!');

    SetLength(Packet, 8 + ModLen);
    PWord(@Packet[0])^ := NtoBE(word(8 + ModLen));
    PWord(@Packet[2])^ := NtoBE(word(2));
    PWord(@Packet[4])^ := NtoBE(word(tcStartRequest));
    PWord(@Packet[6])^ := NtoBE(word(ModLen));

    if ModLen > 0 then
      Move(PubKey.Modulus[1], Packet[8], ModLen);

    FSocket.SendBuffer(@Packet[0], Length(Packet));
    RSA.SavePrivateKey(FPrivKey);
  finally
    RSA.Free;
  end;
end;

procedure TMainNet.ReplyChallenge(const ServerChallenge: rawbytestring);

  function GetChallengeItem(ItemId: byte): TBytes;
  var
    ItemLen, CurItemID: byte;
    Idx, TotalLen: integer;
  begin
    SetLength(Result, 0);
    Idx := 1;
    TotalLen := Length(ServerChallenge);

    while Idx <= TotalLen do
    begin
      ItemLen := byte(ServerChallenge[Idx]);
      Inc(Idx);
      if Idx > TotalLen then Break;

      CurItemID := byte(ServerChallenge[Idx]);
      Inc(Idx);

      if CurItemID = ItemId then
      begin
        if (Idx + ItemLen - 1) <= (TotalLen + 1) then
        begin
          SetLength(Result, ItemLen);
          if ItemLen > 0 then
            Move(ServerChallenge[Idx], Result[0], ItemLen);
        end;
        Exit;
      end;
      Inc(Idx, ItemLen);
    end;
  end;

const
  QCONNDOOR_PERMISSIONS: array[0..4] of byte = (3, 4, 118, 131, 1);
  EMSA_SHA1_HASH: array[0..14] of byte =
    ($30, $21, $30, $09, $06, $05, $2B, $0E, $03, $02, $1A, $05, $00, $04, $14);
var
  DecryptedBlob, HashBuf: TBytes;
  Plain: TBytes;
  SHA1: TSha1;
  Digest: TSha1Digest;
  RSA: TRsa;
  Signature: rawbytestring;
begin
  FSessionKey := GetChallengeItem(CHALLENGE_ITEM_SESSIONKEY);

  SetLength(DecryptedBlob, 35);
  if Length(ServerChallenge) >= 30 then
    Move(ServerChallenge[1], DecryptedBlob[0], 30);
  Move(QCONNDOOR_PERMISSIONS[0], DecryptedBlob[30], 5);

  SHA1.Init;
  SHA1.Update(@DecryptedBlob[0], Length(DecryptedBlob));
  SHA1.Final(Digest);

  SetLength(HashBuf, SizeOf(EMSA_SHA1_HASH) + SizeOf(Digest));
  Move(EMSA_SHA1_HASH[0], HashBuf[0], SizeOf(EMSA_SHA1_HASH));
  Move(Digest[0], HashBuf[SizeOf(EMSA_SHA1_HASH)], SizeOf(Digest));

  RSA := TRsa.Create;
  try
    RSA.LoadFromPrivateKey(FPrivKey);
    Signature := RSA.Pkcs1Sign(@HashBuf[0], Length(HashBuf));
  finally
    RSA.Free;
  end;

  SetLength(Plain, 6 + Length(DecryptedBlob) + Length(Signature));
  PWord(@Plain[0])^ := NtoBE(word(4 + Length(DecryptedBlob) + Length(Signature)));
  PWord(@Plain[2])^ := NtoBE(word(Length(DecryptedBlob)));
  PWord(@Plain[4])^ := NtoBE(word(Length(Signature)));

  Move(DecryptedBlob[0], Plain[6], Length(DecryptedBlob));
  if Length(Signature) > 0 then
    Move(PChar(Signature)^, Plain[6 + Length(DecryptedBlob)], Length(Signature));

  LogMsg('Authenticating with target credentials.');
  AESEncryptSend(Plain, Ord(tcDecryptedChallengeResponse));
end;

procedure TMainNet.AESEncryptSend(const Plain: TBytes; Code: word);
var
  Encrypted, Packet, Header, FullPacket: TBytes;
  TotalLen: integer;
  AES: TAesCbc;
  IV: TAesBlock;
begin
  if Length(FSessionKey) = 0 then
  begin
    LogMsg('Error: Missing Session Key for AES encryption.');
    Exit;
  end;

  AES := TAesCbc.Create(FSessionKey);
  try
    RandomBytes(@IV[0], SizeOf(IV));
    AES.IV := IV;
    Encrypted := AES.EncryptPkcs7(Plain);
  finally
    AES.Free;
  end;

  SetLength(Packet, 4 + SizeOf(IV) + Length(Encrypted));
  PWord(@Packet[0])^ := NtoBE(word(Length(Encrypted)));
  PWord(@Packet[2])^ := NtoBE(word(Length(Plain)));
  Move(IV[0], Packet[4], SizeOf(IV));
  if Length(Encrypted) > 0 then
    Move(Encrypted[0], Packet[20], Length(Encrypted));

  SetLength(Header, 6);
  TotalLen := Length(Header) + Length(Packet);
  PWord(@Header[0])^ := NtoBE(word(TotalLen));
  PWord(@Header[2])^ := NtoBE(word(2));
  PWord(@Header[4])^ := NtoBE(word(Code));

  SetLength(FullPacket, TotalLen);
  Move(Header[0], FullPacket[0], Length(Header));
  Move(Packet[0], FullPacket[Length(Header)], Length(Packet));

  FSocket.SendBuffer(@FullPacket[0], Length(FullPacket));
end;

procedure TMainNet.Authorise(const Data: TBytes);
var
  Plain: TBytes;
  Iterations: integer;
  SaltLength, ChallengeLength: smallint;
  Salt, Challenge, HashedData: TBytes;
  HashStr: string;
begin
  if Length(Data) < 18 then Exit;

  Iterations := BEtoN(PInteger(@Data[10])^);
  SaltLength := BEtoN(PWord(@Data[14])^);
  ChallengeLength := BEtoN(PWord(@Data[16])^);

  if Length(Data) < (18 + SaltLength + ChallengeLength) then Exit;

  SetLength(Salt, SaltLength);
  SetLength(Challenge, ChallengeLength);

  if SaltLength > 0 then
    Move(Data[18], Salt[0], SaltLength);
  if ChallengeLength > 0 then
    Move(Data[18 + SaltLength], Challenge[0], ChallengeLength);

  HashedData := HashPassV2(Challenge, Salt, FPassword, Iterations);

  HashStr := UpperCase(BytesToHex(HashedData));
  FHashedPassword := rawbytestring(HashStr);

  SetLength(Plain, 2 + Length(FHashedPassword));
  PWord(@Plain[0])^ := NtoBE(word(Length(FHashedPassword)));
  if Length(FHashedPassword) > 0 then
    Move(PChar(FHashedPassword)^, Plain[2], Length(FHashedPassword));

  AESEncryptSend(Plain, Ord(tcAuthenticate));
end;

end.
