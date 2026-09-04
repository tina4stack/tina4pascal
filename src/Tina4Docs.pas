unit Tina4Docs;

{ A tiny, dependency-free document store for Tina4Pascal — the "our SQLite"
  answer. Instead of building a SQL engine (a multi-year job), this keeps JSON
  documents in named collections with id lookup and simple equality queries.
  Pure Pascal (fpjson) — no C, no system library — so it cross-compiles to all
  targets unchanged. Covers settings, cached API records, offline lists: the
  ~85% of app data that isn't relational joins.

  Persistence: one JSON-lines file per collection in the app data dir, rewritten
  on change and loaded on init. The boundary is JSON TEXT (strings), so there is
  no object-ownership to reason about:

    id := DocInsert('todos', jsonText);   // returns the new id
    j  := DocGet('todos', id);            // JSON text, or '' if missing
    DocUpdate('todos', id, jsonText);     // replace, keep the id
    arr := DocFindEq('todos', 'done', 'true');   // JSON array of matches
    DocDelete('todos', id);

  For real relational SQL, vendor the SQLite amalgamation instead — but reach
  for that only when you actually need joins. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, fpjson, jsonparser;

{ Point the store at the app's writable data dir (from the shell); loads any
  existing collections. Call once at startup. }
procedure DocsInit(const DataDir: string);

{ Insert JsonDoc (a JSON object) into Collection; assigns and returns a new id
  (an "id" field is added to the stored document). '' if JsonDoc is invalid. }
function DocInsert(const Collection, JsonDoc: string): string;
{ The document's JSON text, or '' if not found. }
function DocGet(const Collection, Id: string): string;
{ Replace the document at Id (keeps its id); False if it doesn't exist. }
function DocUpdate(const Collection, Id, JsonDoc: string): Boolean;
function DocDelete(const Collection, Id: string): Boolean;
{ Every document as a JSON array text (insertion order). }
function DocAll(const Collection: string): string;
{ Documents whose top-level Field equals Value (compared as text), as a JSON
  array text. }
function DocFindEq(const Collection, Field, Value: string): string;
function DocCount(const Collection: string): Integer;
{ Remove every document in Collection (and its file). }
procedure DocClear(const Collection: string);

implementation

type
  TCollection = class
    Ids: TStringList;                       // insertion order
    Docs: TDictionary<string, string>;      // id → JSON text
    NextId: Integer;
    Path: string;
    constructor Create;
    destructor Destroy; override;
    procedure Load;
    procedure Save;
  end;

var
  GDir: string = '';
  GCols: TObjectDictionary<string, TCollection> = nil;

constructor TCollection.Create;
begin
  Ids := TStringList.Create;
  Docs := TDictionary<string, string>.Create;
  NextId := 0;
end;

destructor TCollection.Destroy;
begin
  Ids.Free; Docs.Free;
  inherited;
end;

procedure TCollection.Load;
var f: TStringList; i, n: Integer; line, id: string; j: TJSONData; o: TJSONObject;
begin
  if (Path = '') or not FileExists(Path) then Exit;
  f := TStringList.Create;
  try
    f.LoadFromFile(Path);
    for i := 0 to f.Count - 1 do
    begin
      line := Trim(f[i]);
      if line = '' then Continue;
      j := nil;
      try j := GetJSON(line); except j := nil; end;
      if (j = nil) or not (j is TJSONObject) then begin j.Free; Continue; end;
      o := TJSONObject(j);
      id := o.Get('id', '');
      if id <> '' then
      begin
        Docs.AddOrSetValue(id, line);
        Ids.Add(id);
        n := StrToIntDef(id, 0);
        if n >= NextId then NextId := n + 1;   // keep numeric ids monotonic
      end;
      j.Free;
    end;
  finally
    f.Free;
  end;
end;

procedure TCollection.Save;
var f: TStringList; i: Integer; s: string;
begin
  if Path = '' then Exit;
  f := TStringList.Create;
  try
    for i := 0 to Ids.Count - 1 do
      if Docs.TryGetValue(Ids[i], s) then f.Add(s);
    f.SaveToFile(Path);
  finally
    f.Free;
  end;
end;

procedure DocsInit(const DataDir: string);
begin
  GDir := DataDir;
  if GCols <> nil then GCols.Free;
  GCols := TObjectDictionary<string, TCollection>.Create([doOwnsValues]);
end;

procedure EnsureCols;
begin
  if GCols = nil then
    GCols := TObjectDictionary<string, TCollection>.Create([doOwnsValues]);
end;

{ get (loading from disk the first time) the named collection }
function Col(const Name: string): TCollection;
begin
  EnsureCols;
  if not GCols.TryGetValue(Name, Result) then
  begin
    Result := TCollection.Create;
    if GDir <> '' then
      Result.Path := IncludeTrailingPathDelimiter(GDir) + 'docs_' + Name + '.jsonl';
    Result.Load;
    GCols.Add(Name, Result);
  end;
end;

{ parse a doc, force its "id" to Id, return canonical JSON text ('' on error) }
function WithId(const JsonDoc, Id: string): string;
var j: TJSONData; o: TJSONObject;
begin
  Result := '';
  j := nil;
  try j := GetJSON(JsonDoc); except j := nil; end;
  if (j = nil) or not (j is TJSONObject) then begin j.Free; Exit; end;
  o := TJSONObject(j);
  o.Delete('id');
  o.Add('id', Id);          // id is always a string field
  Result := o.AsJSON;
  j.Free;
end;

function DocInsert(const Collection, JsonDoc: string): string;
var c: TCollection; stored: string;
begin
  Result := '';
  c := Col(Collection);
  Result := IntToStr(c.NextId);
  stored := WithId(JsonDoc, Result);
  if stored = '' then begin Result := ''; Exit; end;   // invalid JSON
  Inc(c.NextId);
  c.Docs.AddOrSetValue(Result, stored);
  c.Ids.Add(Result);
  c.Save;
end;

function DocGet(const Collection, Id: string): string;
begin
  if not Col(Collection).Docs.TryGetValue(Id, Result) then Result := '';
end;

function DocUpdate(const Collection, Id, JsonDoc: string): Boolean;
var c: TCollection; stored: string;
begin
  c := Col(Collection);
  Result := c.Docs.ContainsKey(Id);
  if not Result then Exit;
  stored := WithId(JsonDoc, Id);
  if stored = '' then Exit(False);
  c.Docs[Id] := stored;
  c.Save;
end;

function DocDelete(const Collection, Id: string): Boolean;
var c: TCollection; idx: Integer;
begin
  c := Col(Collection);
  Result := c.Docs.ContainsKey(Id);
  if not Result then Exit;
  c.Docs.Remove(Id);
  idx := c.Ids.IndexOf(Id);
  if idx >= 0 then c.Ids.Delete(idx);
  c.Save;
end;

function DocAll(const Collection: string): string;
var c: TCollection; i: Integer; s: string; sb: TStringBuilder;
begin
  c := Col(Collection);
  sb := TStringBuilder.Create;
  try
    sb.Append('[');
    for i := 0 to c.Ids.Count - 1 do
    begin
      if c.Docs.TryGetValue(c.Ids[i], s) then
      begin
        if sb.Length > 1 then sb.Append(',');
        sb.Append(s);
      end;
    end;
    sb.Append(']');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ a field's value as a JSON-idiomatic string, so a query for a boolean field
  matches 'true'/'false' (fpjson's AsString would give 'True'/'False'). }
function JsonValStr(D: TJSONData): string;
begin
  case D.JSONType of
    jtBoolean: if D.AsBoolean then Result := 'true' else Result := 'false';
    jtNull:    Result := 'null';
  else
    Result := D.AsString;
  end;
end;

function DocFindEq(const Collection, Field, Value: string): string;
var
  c: TCollection; i: Integer; s: string; sb: TStringBuilder;
  j: TJSONData; o: TJSONObject; fv: TJSONData;
begin
  c := Col(Collection);
  sb := TStringBuilder.Create;
  try
    sb.Append('[');
    for i := 0 to c.Ids.Count - 1 do
    begin
      if not c.Docs.TryGetValue(c.Ids[i], s) then Continue;
      j := nil;
      try j := GetJSON(s); except j := nil; end;
      if (j <> nil) and (j is TJSONObject) then
      begin
        o := TJSONObject(j);
        fv := o.Find(Field);
        if (fv <> nil) and (JsonValStr(fv) = Value) then
        begin
          if sb.Length > 1 then sb.Append(',');
          sb.Append(s);
        end;
      end;
      j.Free;
    end;
    sb.Append(']');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function DocCount(const Collection: string): Integer;
begin
  Result := Col(Collection).Ids.Count;
end;

procedure DocClear(const Collection: string);
var c: TCollection;
begin
  c := Col(Collection);
  c.Docs.Clear; c.Ids.Clear;
  if (c.Path <> '') and FileExists(c.Path) then DeleteFile(c.Path);
end;

initialization
finalization
  GCols.Free;
end.
