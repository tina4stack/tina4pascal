unit Tina4Services;

{ App services for Tina4Pascal — the data/runtime layer that sits alongside the
  HTML renderer. This unit holds the PORTABLE services (pure Pascal, no OS
  dependency beyond a writable data directory the shell points us at):

    • Tina4Cache — an in-memory key/value cache with per-entry TTL. Lives only
      for the process; ideal for API responses, computed values, view state.

    • Tina4Store — a persistent key/value "localStore", flushed to a small file
      in the app's data directory, so values survive relaunch.

  Networked services (HTTP API, WebSocket) and SQLite are declared as contracts
  elsewhere and implemented per shell, because they need the platform's TLS /
  socket / sqlite stack. These two need none of that, so they run identically on
  macOS, Windows, Linux, Android and iOS.

  App code (an action handler registered with Tina4Events) calls these directly,
  then mutates the DOM and lets the next frame repaint. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections;

{ ---- memory cache (TTL) ------------------------------------------------- }
{ Store Value under Key for TTLSeconds (<= 0 = no expiry). Overwrites. }
procedure CachePut(const Key, Value: string; TTLSeconds: Double = 0);
{ True + Value if Key is present and not expired; expired entries are dropped. }
function  CacheGet(const Key: string; out Value: string): Boolean;
{ Convenience: the value, or Default if missing/expired. }
function  CacheGetDef(const Key, Default: string): string;
function  CacheHas(const Key: string): Boolean;
procedure CacheDelete(const Key: string);
procedure CacheClear;
{ Drop every expired entry now (also happens lazily on access). Returns count. }
function  CacheSweep: Integer;
function  CacheCount: Integer;

{ ---- persistent localStore --------------------------------------------- }
{ Point the store at the app's writable data directory (from the shell). Loads
  any existing store. Call once at startup, before the first Store* call. }
procedure StoreInit(const DataDir: string);
procedure StoreSet(const Key, Value: string);
function  StoreGet(const Key: string; out Value: string): Boolean;
function  StoreGetDef(const Key, Default: string): string;
function  StoreHas(const Key: string): Boolean;
procedure StoreDelete(const Key: string);
procedure StoreClear;
function  StoreKeys: TArray<string>;

implementation

{ ---- memory cache ------------------------------------------------------- }

type
  TCacheEntry = record
    Value: string;
    Expires: TDateTime;   // 0 = never
  end;

var
  GCache: TDictionary<string, TCacheEntry> = nil;

procedure EnsureCache;
begin
  if GCache = nil then GCache := TDictionary<string, TCacheEntry>.Create;
end;

function Expired(const E: TCacheEntry): Boolean;
begin
  Result := (E.Expires <> 0) and (Now >= E.Expires);
end;

procedure CachePut(const Key, Value: string; TTLSeconds: Double);
var e: TCacheEntry;
begin
  EnsureCache;
  e.Value := Value;
  if TTLSeconds > 0 then e.Expires := Now + TTLSeconds / 86400.0 else e.Expires := 0;
  GCache.AddOrSetValue(Key, e);
end;

function CacheGet(const Key: string; out Value: string): Boolean;
var e: TCacheEntry;
begin
  Value := '';
  Result := False;
  if GCache = nil then Exit;
  if not GCache.TryGetValue(Key, e) then Exit;
  if Expired(e) then begin GCache.Remove(Key); Exit; end;
  Value := e.Value;
  Result := True;
end;

function CacheGetDef(const Key, Default: string): string;
begin
  if not CacheGet(Key, Result) then Result := Default;
end;

function CacheHas(const Key: string): Boolean;
var s: string;
begin
  Result := CacheGet(Key, s);
end;

procedure CacheDelete(const Key: string);
begin
  if GCache <> nil then GCache.Remove(Key);
end;

procedure CacheClear;
begin
  if GCache <> nil then GCache.Clear;
end;

function CacheSweep: Integer;
var pair: TPair<string, TCacheEntry>; dead: TList<string>; k: string;
begin
  Result := 0;
  if GCache = nil then Exit;
  dead := TList<string>.Create;
  try
    for pair in GCache do
      if Expired(pair.Value) then dead.Add(pair.Key);
    for k in dead do GCache.Remove(k);
    Result := dead.Count;
  finally
    dead.Free;
  end;
end;

function CacheCount: Integer;
begin
  if GCache = nil then Result := 0 else Result := GCache.Count;
end;

{ ---- persistent localStore --------------------------------------------- }

var
  GStore: TDictionary<string, string> = nil;
  GStorePath: string = '';

{ escape a key/value so it survives one-line-per-field serialisation }
function Esc(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '\r', [rfReplaceAll]);
end;

function Unesc(const S: string): string;
var i: Integer; c: Char;
begin
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    c := S[i];
    if (c = '\') and (i < Length(S)) then
    begin
      Inc(i);
      case S[i] of
        'n': Result := Result + #10;
        'r': Result := Result + #13;
        '\': Result := Result + '\';
      else Result := Result + S[i];
      end;
    end
    else Result := Result + c;
    Inc(i);
  end;
end;

procedure StoreLoad;
var f: TStringList; i, p: Integer; line: string;
begin
  GStore.Clear;
  if (GStorePath = '') or not FileExists(GStorePath) then Exit;
  f := TStringList.Create;
  try
    f.LoadFromFile(GStorePath);
    for i := 0 to f.Count - 1 do
    begin
      line := f[i];
      p := Pos(#9, line);              // key<TAB>value
      if p > 0 then
        GStore.AddOrSetValue(Unesc(Copy(line, 1, p - 1)),
                             Unesc(Copy(line, p + 1, MaxInt)));
    end;
  finally
    f.Free;
  end;
end;

procedure StoreFlush;
var f: TStringList; pair: TPair<string, string>;
begin
  if GStorePath = '' then Exit;
  f := TStringList.Create;
  try
    for pair in GStore do
      f.Add(Esc(pair.Key) + #9 + Esc(pair.Value));
    f.SaveToFile(GStorePath);
  finally
    f.Free;
  end;
end;

procedure StoreInit(const DataDir: string);
begin
  if GStore = nil then GStore := TDictionary<string, string>.Create;
  if DataDir <> '' then
    GStorePath := IncludeTrailingPathDelimiter(DataDir) + 'tina4store.dat'
  else
    GStorePath := '';
  StoreLoad;
end;

procedure EnsureStore;
begin
  if GStore = nil then GStore := TDictionary<string, string>.Create;
end;

procedure StoreSet(const Key, Value: string);
begin
  EnsureStore;
  GStore.AddOrSetValue(Key, Value);
  StoreFlush;
end;

function StoreGet(const Key: string; out Value: string): Boolean;
begin
  Value := '';
  Result := (GStore <> nil) and GStore.TryGetValue(Key, Value);
end;

function StoreGetDef(const Key, Default: string): string;
begin
  if not StoreGet(Key, Result) then Result := Default;
end;

function StoreHas(const Key: string): Boolean;
begin
  Result := (GStore <> nil) and GStore.ContainsKey(Key);
end;

procedure StoreDelete(const Key: string);
begin
  if GStore <> nil then begin GStore.Remove(Key); StoreFlush; end;
end;

procedure StoreClear;
begin
  if GStore <> nil then begin GStore.Clear; StoreFlush; end;
end;

function StoreKeys: TArray<string>;
begin
  if GStore = nil then SetLength(Result, 0) else Result := GStore.Keys.ToArray;
end;

initialization
finalization
  GCache.Free;
  GStore.Free;
end.
