unit Tina4Secrets;

{ A tiny cross-platform secret store for the auth session (access/refresh
  tokens). The contract is three calls — Set / Get / Delete a named secret —
  backed by the most secure per-OS store available:

    Windows : DPAPI (CryptProtectData) — encrypted to the current user account,
              at rest under %LOCALAPPDATA%\Tina4\secrets\<name>.
    others  : a per-user file (0600) under ~/.local/share/tina4/secrets — a
              PORTABLE FALLBACK. The real backends (macOS Keychain, Linux
              libsecret, Android Keystore, iOS Keychain) are shell-owned and
              wired on-device — the same boundary as the barcode camera. This
              keeps the flow building and working everywhere, secured with
              DPAPI on Windows today.

  Values are UTF-8 strings (the token JSON). Names are sanitised to a safe file
  stem. TinaSecretBackend reports which store is active (for diagnostics/tests). }

{$mode delphi}{$H+}

interface

function TinaSecretSet(const Name, Value: string): Boolean;
function TinaSecretGet(const Name: string; out Value: string): Boolean;
function TinaSecretDelete(const Name: string): Boolean;
function TinaSecretBackend: string;

implementation

uses
  SysUtils, Classes
  {$IFDEF WINDOWS}, Windows{$ENDIF};

{ ---- where secrets live -------------------------------------------------- }
function SecretsDir: string;
var base: string;
begin
  {$IFDEF WINDOWS}
  base := SysUtils.GetEnvironmentVariable('LOCALAPPDATA');
  if base = '' then base := SysUtils.GetEnvironmentVariable('APPDATA');
  Result := IncludeTrailingPathDelimiter(base) + 'Tina4' + PathDelim + 'secrets';
  {$ELSE}
  base := SysUtils.GetEnvironmentVariable('XDG_DATA_HOME');
  if base = '' then base := IncludeTrailingPathDelimiter(SysUtils.GetEnvironmentVariable('HOME')) + '.local' + PathDelim + 'share';
  Result := IncludeTrailingPathDelimiter(base) + 'tina4' + PathDelim + 'secrets';
  {$ENDIF}
end;

{ letters/digits/._- kept; anything else → '_' so a name is a safe file stem. }
function SafeName(const Name: string): string;
var i: Integer; c: Char;
begin
  Result := '';
  for i := 1 to Length(Name) do
  begin
    c := Name[i];
    if ((c >= 'A') and (c <= 'Z')) or ((c >= 'a') and (c <= 'z')) or
       ((c >= '0') and (c <= '9')) or (c = '.') or (c = '_') or (c = '-') then
      Result := Result + c
    else
      Result := Result + '_';
  end;
  if Result = '' then Result := 'default';
end;

function SecretPath(const Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(SecretsDir) + SafeName(Name) + '.bin';
end;

procedure WriteAllBytes(const Path: string; const Bytes: TBytes);
var fs: TFileStream;
begin
  ForceDirectories(ExtractFilePath(Path));
  fs := TFileStream.Create(Path, fmCreate);
  try if Length(Bytes) > 0 then fs.WriteBuffer(Bytes[0], Length(Bytes)); finally fs.Free; end;
end;

function ReadAllBytes(const Path: string; out Bytes: TBytes): Boolean;
var fs: TFileStream;
begin
  Result := False; SetLength(Bytes, 0);
  if not FileExists(Path) then Exit;
  fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try SetLength(Bytes, fs.Size); if fs.Size > 0 then fs.ReadBuffer(Bytes[0], fs.Size); finally fs.Free; end;
  Result := True;
end;

{ ---- Windows: DPAPI ------------------------------------------------------ }
{$IFDEF WINDOWS}
type
  DATA_BLOB = record cbData: DWORD; pbData: PBYTE; end;
  PDATA_BLOB = ^DATA_BLOB;

function CryptProtectData(pDataIn: PDATA_BLOB; szDataDescr: PWideChar;
  pOptionalEntropy: PDATA_BLOB; pvReserved, pPromptStruct: Pointer;
  dwFlags: DWORD; pDataOut: PDATA_BLOB): BOOL; stdcall; external 'crypt32.dll' name 'CryptProtectData';
function CryptUnprotectData(pDataIn: PDATA_BLOB; ppszDataDescr: PPWideChar;
  pOptionalEntropy: PDATA_BLOB; pvReserved, pPromptStruct: Pointer;
  dwFlags: DWORD; pDataOut: PDATA_BLOB): BOOL; stdcall; external 'crypt32.dll' name 'CryptUnprotectData';
function LocalFree(hMem: HLOCAL): HLOCAL; stdcall; external 'kernel32.dll';

function DpapiProtect(const Plain: TBytes; out Cipher: TBytes): Boolean;
var inB, outB: DATA_BLOB;
begin
  Result := False;
  inB.cbData := Length(Plain); if Length(Plain) > 0 then inB.pbData := @Plain[0] else inB.pbData := nil;
  FillChar(outB, SizeOf(outB), 0);
  if not CryptProtectData(@inB, nil, nil, nil, nil, 0, @outB) then Exit;
  try SetLength(Cipher, outB.cbData); if outB.cbData > 0 then Move(outB.pbData^, Cipher[0], outB.cbData);
  finally if outB.pbData <> nil then LocalFree(HLOCAL(outB.pbData)); end;
  Result := True;
end;

function DpapiUnprotect(const Cipher: TBytes; out Plain: TBytes): Boolean;
var inB, outB: DATA_BLOB;
begin
  Result := False;
  inB.cbData := Length(Cipher); if Length(Cipher) > 0 then inB.pbData := @Cipher[0] else inB.pbData := nil;
  FillChar(outB, SizeOf(outB), 0);
  if not CryptUnprotectData(@inB, nil, nil, nil, nil, 0, @outB) then Exit;
  try SetLength(Plain, outB.cbData); if outB.cbData > 0 then Move(outB.pbData^, Plain[0], outB.cbData);
  finally if outB.pbData <> nil then LocalFree(HLOCAL(outB.pbData)); end;
  Result := True;
end;
{$ENDIF}

{ ---- public API ---------------------------------------------------------- }
function TinaSecretBackend: string;
begin
  {$IFDEF WINDOWS}Result := 'dpapi';{$ELSE}Result := 'file';{$ENDIF}
end;

function StrToBytes(const S: string): TBytes;
begin SetLength(Result, Length(S)); if Length(S) > 0 then Move(S[1], Result[0], Length(S)); end;

function BytesToStr(const B: TBytes): string;
begin SetLength(Result, Length(B)); if Length(B) > 0 then Move(B[0], Result[1], Length(B)); end;

function TinaSecretSet(const Name, Value: string): Boolean;
var plain, stored: TBytes;
begin
  Result := False;
  plain := StrToBytes(Value);
  {$IFDEF WINDOWS}
  if not DpapiProtect(plain, stored) then Exit;
  {$ELSE}
  stored := plain;                 // portable fallback (native keychain = on-device)
  {$ENDIF}
  try WriteAllBytes(SecretPath(Name), stored); Result := True; except Result := False; end;
end;

function TinaSecretGet(const Name: string; out Value: string): Boolean;
var stored, plain: TBytes;
begin
  Result := False; Value := '';
  if not ReadAllBytes(SecretPath(Name), stored) then Exit;
  {$IFDEF WINDOWS}
  if not DpapiUnprotect(stored, plain) then Exit;
  {$ELSE}
  plain := stored;
  {$ENDIF}
  Value := BytesToStr(plain);
  Result := True;
end;

function TinaSecretDelete(const Name: string): Boolean;
var p: string;
begin
  p := SecretPath(Name);
  if FileExists(p) then Result := SysUtils.DeleteFile(p) else Result := True;
end;

end.
