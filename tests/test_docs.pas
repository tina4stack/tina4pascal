program test_docs;

{ Tests the Tina4Docs document store: insert/get/update/delete, equality query,
  count, and persistence across reload. Pure Pascal, no network. Prints
  "ALL TESTS PASS", exits 0 on success. }

{$mode delphi}{$H+}

uses
  SysUtils, fpjson, jsonparser, Tina4Docs;

var
  Passed, Failed: Integer;

procedure Check(Cond: Boolean; const Name: string);
begin
  if Cond then Inc(Passed)
  else begin Inc(Failed); Writeln('FAIL: ', Name); end;
end;

{ pull a top-level string field out of a JSON object text }
function Field(const JsonObj, Name: string): string;
var j: TJSONData; f: TJSONData;
begin
  Result := '';
  j := nil;
  try j := GetJSON(JsonObj); except j := nil; end;
  if (j <> nil) and (j is TJSONObject) then
  begin
    f := TJSONObject(j).Find(Name);
    if f <> nil then
    begin
      if f.JSONType = jtBoolean then
        begin if f.AsBoolean then Result := 'true' else Result := 'false'; end
      else Result := f.AsString;
    end;
  end;
  j.Free;
end;

{ count elements in a JSON array text }
function ArrLen(const JsonArr: string): Integer;
var j: TJSONData;
begin
  Result := -1;
  j := nil;
  try j := GetJSON(JsonArr); except j := nil; end;
  if (j <> nil) and (j is TJSONArray) then Result := TJSONArray(j).Count;
  j.Free;
end;

var
  dir, id1, id2, g, arr: string;
begin
  Passed := 0; Failed := 0;

  dir := IncludeTrailingPathDelimiter(GetTempDir) + 'tina4docs_test';
  ForceDirectories(dir);
  DocsInit(dir);
  DocClear('todos');

  { insert + get }
  id1 := DocInsert('todos', '{"text":"milk","done":false}');
  Check(id1 <> '', 'insert returns id');
  Check(DocCount('todos') = 1, 'count after insert');
  g := DocGet('todos', id1);
  Check((Field(g, 'text') = 'milk') and (Field(g, 'id') = id1), 'get returns doc with id');

  id2 := DocInsert('todos', '{"text":"eggs","done":true}');
  Check(DocCount('todos') = 2, 'count after second insert');
  Check(id2 <> id1, 'ids are distinct');

  { equality query }
  arr := DocFindEq('todos', 'done', 'true');
  Check(ArrLen(arr) = 1, 'findEq matches one');
  Check(Field(Copy(arr, 2, Length(arr) - 2), 'text') = 'eggs', 'findEq returns the right doc');

  { update keeps id, changes field }
  Check(DocUpdate('todos', id1, '{"text":"milk","done":true}'), 'update existing');
  Check(Field(DocGet('todos', id1), 'done') = 'true', 'update changed field');
  Check(DocCount('todos') = 2, 'update keeps count');
  Check(ArrLen(DocFindEq('todos', 'done', 'true')) = 2, 'query reflects update');

  { all }
  Check(ArrLen(DocAll('todos')) = 2, 'all returns both');

  { persistence across reload }
  DocsInit(dir);
  Check(DocCount('todos') = 2, 'persists count');
  Check(Field(DocGet('todos', id1), 'done') = 'true', 'persists update');

  { delete persists }
  Check(DocDelete('todos', id2), 'delete existing');
  Check(DocCount('todos') = 1, 'count after delete');
  DocsInit(dir);
  Check(DocCount('todos') = 1, 'delete persisted');
  Check(DocGet('todos', id2) = '', 'deleted doc gone');

  { invalid json rejected }
  Check(DocInsert('todos', 'not json') = '', 'invalid json rejected');
  Check(DocCount('todos') = 1, 'invalid insert changed nothing');

  DocClear('todos');

  Writeln;
  Writeln(Passed, ' assertions passed, ', Failed, ' failed.');
  if Failed = 0 then begin Writeln('ALL TESTS PASS'); Halt(0); end
  else Halt(1);
end.
