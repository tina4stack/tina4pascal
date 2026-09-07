unit ThreePascalGLTF;

{ GLTFLoader for ThreePascal — parses a binary .glb (the office's ships) into a
  TGroup of meshes. Separate unit so the JSON dependency (FPC fpjson) stays out
  of the core engine; use it only when you load models.

  v0.6 scope: static meshes — POSITION, NORMAL, TEXCOORD_0, indices, per-node
  transforms (matrix or T/R/S with quaternion), and baseColorFactor material
  colour. Node transforms are baked into world-space geometry (fine for static
  props). glTF animation/skins/textures are a later pass. }

{$mode delphi}{$H+}

interface

uses SysUtils, Classes, fpjson, jsonparser, ThreePascal;

type
  TGLTFLoader = class
    function Load(const path: string): TGroup;      // three: loader.load(url) → gltf.scene
  end;

implementation

type PSingleA = ^Single; PWordA = ^Word; PCardinalA = ^Cardinal;

{ ---- local matrix helpers (translate/scale/quat, then TRS) ---- }
function TransM(x, y, z: Single): TMat4;
begin Result:=Mat4Identity; Result.m[12]:=x; Result.m[13]:=y; Result.m[14]:=z; end;
function ScaleM(x, y, z: Single): TMat4;
begin Result:=Mat4Identity; Result.m[0]:=x; Result.m[5]:=y; Result.m[10]:=z; end;
function QuatM(x, y, z, w: Single): TMat4;
begin
  Result:=Mat4Identity;
  Result.m[0]:=1-2*(y*y+z*z); Result.m[1]:=2*(x*y+w*z);   Result.m[2]:=2*(x*z-w*y);
  Result.m[4]:=2*(x*y-w*z);   Result.m[5]:=1-2*(x*x+z*z); Result.m[6]:=2*(y*z+w*x);
  Result.m[8]:=2*(x*z+w*y);   Result.m[9]:=2*(y*z-w*x);   Result.m[10]:=1-2*(x*x+y*y);
end;

var GBin: array of Byte;                            // the glb BIN chunk

function RdF(off: Integer): Single; begin Result:=PSingleA(@GBin[off])^; end;

{ read a VEC3 (or VEC2 padded) FLOAT accessor → array of TV3 }
function ReadV3(accessors, bufferViews: TJSONArray; idx: Integer): TArray<TV3>;
var acc, bv: TJSONObject; count, base, stride, i, o, comps: Integer; ty: string;
begin
  acc:=accessors.Objects[idx];
  bv:=bufferViews.Objects[acc.Get('bufferView', 0)];
  count:=acc.Get('count', 0);
  ty:=acc.Get('type', 'VEC3'); if ty='VEC2' then comps:=2 else comps:=3;
  base:=bv.Get('byteOffset', 0) + acc.Get('byteOffset', 0);
  stride:=bv.Get('byteStride', 0); if stride=0 then stride:=comps*4;
  SetLength(Result, count);
  for i:=0 to count-1 do
  begin
    o:=base + i*stride;
    if comps=2 then Result[i]:=V3(RdF(o), RdF(o+4), 0)
    else Result[i]:=V3(RdF(o), RdF(o+4), RdF(o+8));
  end;
end;

function ReadIndices(accessors, bufferViews: TJSONArray; idx: Integer): TArray<LongWord>;
var acc, bv: TJSONObject; count, base, ct, i, o, unit_: Integer;
begin
  acc:=accessors.Objects[idx];
  bv:=bufferViews.Objects[acc.Get('bufferView', 0)];
  count:=acc.Get('count', 0);
  ct:=acc.Get('componentType', 5123);
  base:=bv.Get('byteOffset', 0) + acc.Get('byteOffset', 0);
  if ct=5125 then unit_:=4 else if ct=5121 then unit_:=1 else unit_:=2;
  SetLength(Result, count);
  for i:=0 to count-1 do
  begin
    o:=base + i*unit_;
    case ct of
      5125: Result[i]:=PCardinalA(@GBin[o])^;
      5121: Result[i]:=GBin[o];
    else    Result[i]:=PWordA(@GBin[o])^;
    end;
  end;
end;

function MatColor(materials: TJSONArray; idx: Integer): LongWord;
var m, pbr: TJSONObject; bcf: TJSONData; arr: TJSONArray; r, g, b: Integer;
begin
  Result:=$cccccc;
  if (materials=nil) or (idx<0) or (idx>=materials.Count) then Exit;
  m:=materials.Objects[idx];
  pbr:=TJSONObject(m.Find('pbrMetallicRoughness'));
  if pbr=nil then Exit;
  bcf:=pbr.Find('baseColorFactor');
  if (bcf=nil) or not (bcf is TJSONArray) then Exit;
  arr:=TJSONArray(bcf);
  if arr.Count<3 then Exit;
  r:=Round(arr.Floats[0]*255); g:=Round(arr.Floats[1]*255); b:=Round(arr.Floats[2]*255);
  Result:=(LongWord(r) shl 16) or (LongWord(g) shl 8) or LongWord(b);
end;

function NodeMatrix(node: TJSONObject): TMat4;
var mArr, tA, rA, sA: TJSONData; a: TJSONArray; i: Integer;
    t, s: TV3; qx, qy, qz, qw: Single;
begin
  mArr:=node.Find('matrix');
  if (mArr<>nil) and (mArr is TJSONArray) and (TJSONArray(mArr).Count=16) then
  begin
    a:=TJSONArray(mArr);
    for i:=0 to 15 do Result.m[i]:=a.Floats[i];        // glTF matrix is column-major
    Exit;
  end;
  t:=V3(0,0,0); s:=V3(1,1,1); qx:=0; qy:=0; qz:=0; qw:=1;
  tA:=node.Find('translation'); if (tA<>nil) and (tA is TJSONArray) then
    with TJSONArray(tA) do t:=V3(Floats[0],Floats[1],Floats[2]);
  sA:=node.Find('scale'); if (sA<>nil) and (sA is TJSONArray) then
    with TJSONArray(sA) do s:=V3(Floats[0],Floats[1],Floats[2]);
  rA:=node.Find('rotation'); if (rA<>nil) and (rA is TJSONArray) then
    with TJSONArray(rA) do begin qx:=Floats[0]; qy:=Floats[1]; qz:=Floats[2]; qw:=Floats[3]; end;
  Result:=Mat4Multiply(TransM(t.x,t.y,t.z), Mat4Multiply(QuatM(qx,qy,qz,qw), ScaleM(s.x,s.y,s.z)));
end;

function TGLTFLoader.Load(const path: string): TGroup;
var
  fs: TFileStream; bytes: array of Byte; jsonStr: string;
  c0len, off, c1len, total: LongWord;
  root, mesh, prim, attribs: TJSONObject;
  meshes, accessors, bufferViews, nodes, materials, prims: TJSONArray;
  scenesArr, sceneNodes: TJSONArray; rootObj: TJSONData;
  grp: TGroup;

  procedure EmitMesh(meshIdx: Integer; const world: TMat4);
  var pi, ti: Integer; positions, normals: TArray<TV3>; hasN: Boolean;
      idxs: TArray<LongWord>; geo: TBufferGeometry; m: TMesh; col: LongWord;
      i0, i1, i2: LongWord; p0, p1, p2, n0, n1, n2: TV3;
      pIdx, nIdx: Integer;
  begin
    mesh:=meshes.Objects[meshIdx];
    prims:=mesh.Arrays['primitives'];
    for pi:=0 to prims.Count-1 do
    begin
      prim:=prims.Objects[pi];
      attribs:=prim.Objects['attributes'];
      pIdx:=attribs.Get('POSITION', -1);
      if pIdx<0 then Continue;
      positions:=ReadV3(accessors, bufferViews, pIdx);
      hasN:=attribs.Find('NORMAL')<>nil;
      if hasN then begin nIdx:=attribs.Get('NORMAL',0); normals:=ReadV3(accessors, bufferViews, nIdx); end;
      if prim.Find('indices')<>nil then
        idxs:=ReadIndices(accessors, bufferViews, prim.Get('indices',0))
      else
      begin
        SetLength(idxs, System.Length(positions));
        for ti:=0 to System.Length(idxs)-1 do idxs[ti]:=ti;
      end;
      col:=MatColor(materials, prim.Get('material', -1));
      geo:=TBufferGeometry.Create;
      ti:=0;
      while ti+2 < System.Length(idxs) do
      begin
        i0:=idxs[ti]; i1:=idxs[ti+1]; i2:=idxs[ti+2];
        p0:=Mat4TransformPoint(world, positions[i0]);
        p1:=Mat4TransformPoint(world, positions[i1]);
        p2:=Mat4TransformPoint(world, positions[i2]);
        if hasN then
        begin
          n0:=Mat4TransformDir(world, normals[i0]);
          n1:=Mat4TransformDir(world, normals[i1]);
          n2:=Mat4TransformDir(world, normals[i2]);
          geo.PushTriN(p0,p1,p2, n0,n1,n2);
        end
        else geo.PushTri(p0,p1,p2);
        ti:=ti+3;
      end;
      m:=TMesh.Create(geo, TMeshStandardMaterial.Create(col));
      grp.Add(m);
    end;
  end;

  procedure Walk(nodeIdx: Integer; const parentM: TMat4);
  var node: TJSONObject; world: TMat4; ch: TJSONData; ca: TJSONArray; i: Integer;
  begin
    node:=nodes.Objects[nodeIdx];
    world:=Mat4Multiply(parentM, NodeMatrix(node));
    if node.Find('mesh')<>nil then EmitMesh(node.Get('mesh',0), world);
    ch:=node.Find('children');
    if (ch<>nil) and (ch is TJSONArray) then
    begin ca:=TJSONArray(ch); for i:=0 to ca.Count-1 do Walk(ca.Integers[i], world); end;
  end;

var i: Integer;
begin
  grp:=TGroup.Create; grp.Name:='gltf'; Result:=grp;

  fs:=TFileStream.Create(path, fmOpenRead);
  try SetLength(bytes, fs.Size); if fs.Size>0 then fs.ReadBuffer(bytes[0], fs.Size);
  finally fs.Free; end;
  if System.Length(bytes)<20 then Exit;
  if PCardinalA(@bytes[0])^ <> $46546C67 then Exit;    // 'glTF' magic → must be .glb

  total:=PCardinalA(@bytes[8])^;
  c0len:=PCardinalA(@bytes[12])^;                       // chunk 0 = JSON
  SetString(jsonStr, PAnsiChar(@bytes[20]), c0len);
  off:=20 + c0len;                                      // chunk 1 = BIN
  if off+8 <= LongWord(System.Length(bytes)) then
  begin
    c1len:=PCardinalA(@bytes[off])^;
    SetLength(GBin, c1len);
    if c1len>0 then Move(bytes[off+8], GBin[0], c1len);
  end;

  rootObj:=GetJSON(jsonStr);
  if not (rootObj is TJSONObject) then Exit;
  root:=TJSONObject(rootObj);
  try
    meshes:=root.Arrays['meshes'];
    accessors:=root.Arrays['accessors'];
    bufferViews:=root.Arrays['bufferViews'];
    nodes:=root.Arrays['nodes'];
    materials:=TJSONArray(root.Find('materials'));

    scenesArr:=TJSONArray(root.Find('scenes'));
    if (scenesArr<>nil) and (scenesArr.Count>0) then
    begin
      sceneNodes:=scenesArr.Objects[root.Get('scene',0)].Arrays['nodes'];
      for i:=0 to sceneNodes.Count-1 do Walk(sceneNodes.Integers[i], Mat4Identity);
    end
    else
      for i:=0 to meshes.Count-1 do EmitMesh(i, Mat4Identity);
  finally
    rootObj.Free;
  end;
end;

end.
