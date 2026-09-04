program test_services;

{ Unit tests for Tina4Services: the in-memory cache (with TTL) and the
  persistent localStore. Prints "ALL TESTS PASS" and exits 0 on success. }

{$mode delphi}{$H+}

uses
  SysUtils, Tina4Services;

var
  Passed, Failed: Integer;

procedure Check(Cond: Boolean; const Name: string);
begin
  if Cond then Inc(Passed)
  else begin Inc(Failed); Writeln('FAIL: ', Name); end;
end;

var
  v, dir, path: string;
  keys: TArray<string>;
begin
  Passed := 0; Failed := 0;

  { ---- memory cache ---- }
  CacheClear;
  CachePut('a', 'apple');
  Check(CacheGet('a', v) and (v = 'apple'), 'cache put/get');
  Check(CacheHas('a'), 'cache has');
  Check(CacheGetDef('missing', 'def') = 'def', 'cache default');
  Check(CacheCount = 1, 'cache count');

  CachePut('a', 'apricot');                 // overwrite
  Check(CacheGet('a', v) and (v = 'apricot'), 'cache overwrite');

  CacheDelete('a');
  Check(not CacheHas('a'), 'cache delete');

  CachePut('t', 'gone', 0.5);               // 0.5s TTL
  Check(CacheHas('t'), 'cache ttl present');
  Sleep(700);
  Check(not CacheHas('t'), 'cache ttl expired');

  CachePut('x', 'x', 0.3); CachePut('y', 'keep');
  Sleep(500);
  Check(CacheSweep = 1, 'cache sweep drops expired only');
  Check(CacheHas('y'), 'cache sweep keeps live');

  { ---- persistent store ---- }
  dir := IncludeTrailingPathDelimiter(GetTempDir) + 'tina4store_test';
  ForceDirectories(dir);
  path := IncludeTrailingPathDelimiter(dir) + 'tina4store.dat';
  if FileExists(path) then DeleteFile(path);

  StoreInit(dir);
  StoreClear;
  StoreSet('token', 'abc123');
  StoreSet('name', 'André');                // non-ASCII round-trip
  StoreSet('note', 'line1'#10'line2'#9'tab'); // newline + tab escaping
  Check(StoreGet('token', v) and (v = 'abc123'), 'store set/get');
  Check(StoreGetDef('missing', 'd') = 'd', 'store default');
  Check(Length(StoreKeys) = 3, 'store keys count');

  // reload from disk → values persist
  StoreInit(dir);
  Check(StoreGet('token', v) and (v = 'abc123'), 'store persists token');
  Check(StoreGet('name', v) and (v = 'André'), 'store persists utf8');
  Check(StoreGet('note', v) and (v = 'line1'#10'line2'#9'tab'), 'store escapes newline/tab');

  StoreDelete('token');
  StoreInit(dir);                           // reload
  Check(not StoreHas('token'), 'store delete persists');
  Check(StoreHas('name'), 'store delete keeps others');

  keys := nil;
  DeleteFile(path); RemoveDir(dir);

  Writeln;
  Writeln(Passed, ' assertions passed, ', Failed, ' failed.');
  if Failed = 0 then begin Writeln('ALL TESTS PASS'); Halt(0); end
  else Halt(1);
end.
