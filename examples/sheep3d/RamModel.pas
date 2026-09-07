unit RamModel;

{ A faithful ThreePascal port of the virtual-office Merino ram
  (public/vendor/ram-builder.js): icosahedron fleece over a boxed skeleton, a
  neck/head with a Roman-profile muzzle, big curling spiral horns, and a jointed
  leg chain (hip→knee→cannon→hoof). The Walking clip is ported from the source's
  Euler keyframes. Facing +Z, feet at y=0. }

{$mode delphi}{$H+}

interface

uses ThreePascal;

function BuildRam: TGroup;
function RamWalkClip: TAnimationClip;

implementation

uses Math;

var
  fleeceMat, faceMat, legMat, muzzleMat, hoofMat, hornMat: TMeshStandardMaterial;

procedure InitMats;
begin
  fleeceMat:=TMeshStandardMaterial.Create($e8e2d4);
  faceMat  :=TMeshStandardMaterial.Create($f4f0e8);
  legMat   :=TMeshStandardMaterial.Create($bdae9c);
  muzzleMat:=TMeshStandardMaterial.Create($c9a09c);
  hoofMat  :=TMeshStandardMaterial.Create($2f2a26);
  hornMat  :=TMeshStandardMaterial.Create($caa877);
  { closed shapes — cull back faces (~half the fill), keeps 2x AA fast }
  fleeceMat.Side:=msFront; faceMat.Side:=msFront; legMat.Side:=msFront;
  muzzleMat.Side:=msFront; hoofMat.Side:=msFront; hornMat.Side:=msFront;
end;

function Pv(const nm: string; x, y, z: Single): TGroup;
begin Result:=TGroup.Create; Result.Name:=nm; Result.Position.SetXYZ(x,y,z); end;

function Box(par: TObject3D; w,h,d: Single; mat: TMaterial; const nm: string; x,y,z: Single): TMesh;
begin
  Result:=TMesh.Create(TBoxGeometry.Create(w,h,d), mat);
  Result.Name:=nm; Result.Position.SetXYZ(x,y,z); par.Add(Result);
end;

function Lump(par: TObject3D; r: Single; mat: TMaterial; const nm: string; x,y,z, sx,sy,sz: Single): TMesh;
begin
  Result:=TMesh.Create(TIcosahedronGeometry.Create(r,0), mat);
  Result.Name:=nm; Result.Position.SetXYZ(x,y,z); Result.Scale.SetXYZ(sx,sy,sz); par.Add(Result);
end;

{ orient local +Y along direction d (for the horn cylinder segments) }
procedure AlignYToDir(m: TObject3D; dx, dy, dz: Single);
var l: Single;
begin
  l:=Sqrt(dx*dx+dy*dy+dz*dz); if l<1e-9 then l:=1; dx:=dx/l; dy:=dy/l; dz:=dz/l;
  if dx>1 then dx:=1; if dx<-1 then dx:=-1;
  m.Rotation.z:=ArcSin(-dx);
  m.Rotation.x:=ArcTan2(dz, dy);
  m.Rotation.y:=0;
end;

function BuildRam: TGroup;
var ram, stance, body, neck, head, jaw, ep, hg, tail, hip, knee, cannon: TGroup;
    bridge, snout: TMesh; s: Integer; sf: Single; side: string;
    i: Integer; t0, t1, th, rr, len, rad: Single; ax, ay, az, bx, by, bz: Single;
    seg: TMesh; front: Boolean;
  const THIGH = 0.20; SHIN = 0.13; CANLEN = 0.16;
  procedure HornPt(sg, t: Single; out px, py, pz: Single);
  begin
    th:=t*1.9*Pi*2; rr:=0.20*(1-0.5*t);
    px:=sg*(0.02 + 0.10*t + 0.16*t*t*t) + sg*Sin(th)*0.02;
    py:=rr*Cos(th) - 0.20 - 0.02*t;
    pz:=-rr*Sin(th) + 0.05*t;
  end;
  procedure MakeLeg(const id: string; lx, lz: Single);
  begin
    front:=id[1]='f';
    hip:=Pv('leg_'+id, lx, 0.56, lz); if front then hip.Rotation.x:=0 else hip.Rotation.x:=-0.12; body.Add(hip);
    Box(hip, 0.13, THIGH, 0.15, fleeceMat, 'thigh_'+id, 0, -THIGH/2, 0);
    knee:=Pv('knee_'+id, 0, -THIGH, 0); if front then knee.Rotation.x:=0.04 else knee.Rotation.x:=0.22; hip.Add(knee);
    Box(knee, 0.10, SHIN, 0.11, legMat, 'shin_'+id, 0, -SHIN/2, 0);
    cannon:=Pv('cannon_'+id, 0, -SHIN, 0); if front then cannon.Rotation.x:=-0.04 else cannon.Rotation.x:=-0.12; knee.Add(cannon);
    Box(cannon, 0.08, CANLEN, 0.09, legMat, 'cannon_mesh_'+id, 0, -CANLEN/2, 0);
    Box(cannon, 0.10, 0.07, 0.12, hoofMat, 'hoof_'+id, 0, -CANLEN-0.035, 0.01);
  end;
begin
  InitMats;
  ram:=TGroup.Create; ram.Name:='merino_ram';
  stance:=Pv('stance',0,0,0); ram.Add(stance);
  body:=Pv('body',0,0,0); stance.Add(body);

  { barrel body + fleece lumps }
  Box(body, 0.46, 0.44, 0.86, fleeceMat, 'torso', 0, 0.72, -0.04);
  Lump(body,0.20, fleeceMat,'fleece_0', -0.16,0.86,0.30, 1.0,0.9,1.0);
  Lump(body,0.22, fleeceMat,'fleece_1',  0.14,0.88,0.28, 1.0,0.95,1.0);
  Lump(body,0.21, fleeceMat,'fleece_2', -0.14,0.86,-0.14, 1.0,0.9,1.0);
  Lump(body,0.23, fleeceMat,'fleece_3',  0.15,0.90,-0.18, 1.0,0.95,1.0);
  Lump(body,0.20, fleeceMat,'fleece_4', -0.15,0.84,-0.44, 1.0,0.9,1.0);
  Lump(body,0.21, fleeceMat,'fleece_5',  0.14,0.88,-0.46, 1.0,0.9,1.0);
  Lump(body,0.17, fleeceMat,'fleece_6',  0,0.98,0.06, 1.15,0.8,1.2);
  Lump(body,0.17, fleeceMat,'fleece_7',  0,0.97,-0.34, 1.15,0.8,1.2);
  Lump(body,0.15, fleeceMat,'fleece_8',  0,0.60,-0.52, 1.1,0.85,0.9);
  Lump(body,0.17, fleeceMat,'fleece_9', -0.20,0.62,0.08, 0.85,1.0,1.15);
  Lump(body,0.17, fleeceMat,'fleece_10', 0.20,0.62,0.08, 0.85,1.0,1.15);
  Lump(body,0.17, fleeceMat,'fleece_11',-0.20,0.60,-0.34, 0.85,1.0,1.15);
  Lump(body,0.17, fleeceMat,'fleece_12', 0.20,0.60,-0.34, 0.85,1.0,1.15);
  Lump(body,0.15, fleeceMat,'fleece_13', 0,0.56,-0.10, 1.3,0.8,1.1);
  Box(body, 0.34, 0.26, 0.24, fleeceMat, 'brisket', 0, 0.66, 0.40);

  { neck + head }
  neck:=Pv('neck', 0, 0.88, 0.40); neck.Rotation.x:=-0.30; body.Add(neck);
  Lump(neck,0.185, fleeceMat,'neck_mesh',0,0.16,0.02, 1.0,1.3,1.0);
  Lump(neck,0.16, fleeceMat,'ruff_l',-0.11,0.06,0.05, 0.9,1.1,0.9);
  Lump(neck,0.16, fleeceMat,'ruff_r', 0.11,0.06,0.05, 0.9,1.1,0.9);
  Lump(neck,0.15, fleeceMat,'ruff_front',0,0.02,0.13, 1.1,1.0,0.85);

  head:=Pv('head', 0, 0.34, 0.08); head.Rotation.x:=0.30; neck.Add(head);
  Box(head, 0.215,0.22,0.20, faceMat,'skull',0,0.05,0.04);
  Lump(head,0.14, fleeceMat,'poll_wool',0,0.15,-0.02, 1.35,0.95,1.15);
  Lump(head,0.10, fleeceMat,'cheek_wool_l',-0.115,-0.01,-0.02, 0.8,1.1,1.0);
  Lump(head,0.10, fleeceMat,'cheek_wool_r', 0.115,-0.01,-0.02, 0.8,1.1,1.0);
  bridge:=Box(head,0.155,0.14,0.20, faceMat,'nasal_bridge',0,-0.005,0.21); bridge.Rotation.x:=-0.16;
  snout:=Box(head,0.125,0.11,0.10, faceMat,'muzzle',0,-0.075,0.335); snout.Rotation.x:=-0.16;
  Box(head,0.10,0.055,0.035, muzzleMat,'nose',0,-0.055,0.385);

  jaw:=Pv('muzzle_pivot',0,-0.055,0.13); head.Add(jaw);
  Box(jaw,0.115,0.07,0.20, faceMat,'jaw',0,-0.045,0.10);
  Box(jaw,0.09,0.035,0.05, muzzleMat,'lip',0,-0.05,0.205);

  for s:=0 to 1 do
  begin
    if s=1 then begin sf:=1; side:='r'; end else begin sf:=-1; side:='l'; end;
    Lump(head,0.036, hoofMat,'eye_'+side, sf*0.108,0.075,0.115, 0.6,1,1.05);
    Lump(head,0.05, fleeceMat,'brow_'+side, sf*0.09,0.135,0.09, 1.1,0.55,1.0);
    ep:=Pv('ear_pivot_'+side, sf*0.12,-0.01,-0.04); ep.Rotation.z:=-sf*1.15; ep.Rotation.x:=-0.15; head.Add(ep);
    Box(ep,0.05,0.14,0.09, legMat,'ear_'+side,0,0.06,0);
  end;

  { curling horns — spiral cylinder chain }
  for s:=0 to 1 do
  begin
    if s=1 then begin sf:=1; side:='r'; end else begin sf:=-1; side:='l'; end;
    hg:=Pv('horn_'+side, sf*0.085,0.14,-0.07); head.Add(hg);
    for i:=0 to 16 do
    begin
      t0:=i/17; t1:=(i+1)/17;
      HornPt(sf,t0, ax,ay,az); HornPt(sf,t1, bx,by,bz);
      len:=Sqrt(Sqr(bx-ax)+Sqr(by-ay)+Sqr(bz-az));
      rad:=0.058*(1-0.55*t0);
      seg:=TMesh.Create(TCylinderGeometry.Create(rad*0.92, rad, len*1.12, 6), hornMat);
      seg.Position.SetXYZ((ax+bx)/2, (ay+by)/2, (az+bz)/2);
      AlignYToDir(seg, bx-ax, by-ay, bz-az);
      hg.Add(seg);
    end;
  end;

  { tail + legs }
  tail:=Pv('tail',0,0.86,-0.50); tail.Rotation.x:=-0.5; body.Add(tail);
  Lump(tail,0.09, fleeceMat,'tail_mesh',0,-0.07,-0.02, 0.9,1.2,0.9);

  MakeLeg('fl', -0.16, 0.30); MakeLeg('fr', 0.16, 0.30);
  MakeLeg('bl', -0.16, -0.34); MakeLeg('br', 0.16, -0.34);

  Result:=ram;
end;

{ ---- Walking clip (ported from the source Euler keyframes) ---- }
const
  WT: array[0..8] of Single = (0, 0.1375, 0.275, 0.4125, 0.55, 0.6875, 0.825, 0.9625, 1.1);
  SWING: array[0..8] of Single = (0.26, 0.14, -0.02, -0.16, -0.24, -0.12, 0.06, 0.2, 0.26);
  FLEX:  array[0..8] of Single = (0.02, 0.2, 0.34, 0.24, 0.06, 0.02, 0.02, 0.02, 0.02);

function RamWalkClip: TAnimationClip;
var clip: TAnimationClip;
  { phase-shift a 9-sample loop like the JS slice(ph).concat(slice(1,ph+1)) }
  function Shift(const src: array of Single; ph: Integer): TArray<Single>;
  var k, n: Integer;
  begin
    n:=9; SetLength(Result, n);
    for k:=0 to n-1 do
      if k < n-ph then Result[k]:=src[ph+k] else Result[k]:=src[1 + (k-(n-ph))];
  end;
  procedure RotTrack(const nm: string; const vals: array of Single; addX: Single);
  var tr: TKeyframeTrack; k: Integer;
  begin
    tr:=TKeyframeTrack.Create(nm, ttRotation);
    for k:=0 to 8 do tr.AddKey(WT[k], V3(vals[k]+addX, 0, 0));
    clip.AddTrack(tr);
  end;
  procedure PosBob;
  var tr: TKeyframeTrack; ys: array[0..8] of Single; k: Integer;
  begin
    ys[0]:=0; ys[1]:=0.018; ys[2]:=0.004; ys[3]:=0.018; ys[4]:=0;
    ys[5]:=0.018; ys[6]:=0.004; ys[7]:=0.018; ys[8]:=0;
    tr:=TKeyframeTrack.Create('body', ttPosition);
    for k:=0 to 8 do tr.AddKey(WT[k], V3(0, ys[k], 0));
    clip.AddTrack(tr);
  end;
  procedure NeckHead(const nm: string; base: Single);
  var tr: TKeyframeTrack; d: array[0..8] of Single; k: Integer;
  begin
    d[0]:=0; d[1]:=0.03; d[2]:=0; d[3]:=-0.03; d[4]:=0; d[5]:=0.03; d[6]:=0; d[7]:=-0.03; d[8]:=0;
    tr:=TKeyframeTrack.Create(nm, ttRotation);
    for k:=0 to 8 do tr.AddKey(WT[k], V3(base+d[k], 0, 0));   // neck base -0.30, head +0.30
    clip.AddTrack(tr);
  end;
begin
  clip:=TAnimationClip.Create('Walking', 1.1);
  RotTrack('leg_fl', Shift(SWING,0), 0);      RotTrack('knee_fl', Shift(FLEX,0), 0.04);
  RotTrack('leg_fr', Shift(SWING,4), 0);      RotTrack('knee_fr', Shift(FLEX,4), 0.04);
  RotTrack('leg_bl', Shift(SWING,4), -0.12);  RotTrack('knee_bl', Shift(FLEX,4), 0.22);
  RotTrack('leg_br', Shift(SWING,0), -0.12);  RotTrack('knee_br', Shift(FLEX,0), 0.22);
  PosBob;
  NeckHead('neck', -0.30);
  NeckHead('head',  0.30);
  Result:=clip;
end;

end.
