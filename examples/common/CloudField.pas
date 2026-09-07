unit CloudField;

{ Faithful ThreePascal port of the virtual-office puffy clouds
  (public/office.js buildClouds / driftClouds): 16 clusters of squashed-sphere
  "puffs" — ONE InstancedMesh, one draw call — drifting across the sky and
  wrapping around. Same fixed pseudo-pattern (no RNG) so the sky is identical
  every load. A single WORLD scale shrinks the office's huge bay-scale layout to
  whatever scene it's dropped in (the office uses 1.0; the little sheep sky ~0.025).

  Usage:
    clouds := BuildClouds(scene, 0.025);   // add to the scene
    ...each frame: DriftClouds(clouds, 1/60);  // slide + wrap }

{$mode delphi}{$H+}

interface

uses ThreePascal;

type
  TCloud = record baseX, y, z, speed, drift: Single; end;
  TPuff  = record ci: Integer; lx, ly, lz, sx, sy, sz: Single; end;
  TCloudField = class
    Inst: TInstancedMesh;
    Clouds: array of TCloud;
    Puffs: array of TPuff;
    Scale: Single;
    procedure Drift(dt: Single);
  end;

function BuildClouds(scene: TScene; worldScale: Single): TCloudField;
procedure DriftClouds(cf: TCloudField; dt: Single);

implementation

uses Math;

const CLOUD_X = 380;   // office units — a cloud wraps when it drifts past +CLOUD_X

function BuildClouds(scene: TScene; worldScale: Single): TCloudField;
var mat: TMeshStandardMaterial; i, p, n, np: Integer; r: Single;
begin
  Result := TCloudField.Create; Result.Scale := worldScale;
  SetLength(Result.Clouds, 16);
  np := 0;
  for i := 0 to 15 do
  begin
    Result.Clouds[i].baseX := Sin(i*2.3)*320;
    Result.Clouds[i].y     := 82 + (i mod 4)*18;
    Result.Clouds[i].z     := -280 + ((i*61) mod 320);
    Result.Clouds[i].speed := 0.7 + (i mod 5)*0.35;
    Result.Clouds[i].drift := 0;
    n := 4 + (i mod 3);
    for p := 0 to n-1 do
    begin
      r := 9 + ((i*3 + p*7) mod 9);
      SetLength(Result.Puffs, np+1);
      Result.Puffs[np].ci := i;
      Result.Puffs[np].lx := (p - n/2)*13 + Sin(i+p)*4;
      Result.Puffs[np].ly := Cos(p+i)*4;
      Result.Puffs[np].lz := Sin(p*1.7)*9;
      Result.Puffs[np].sx := r*1.7;      // squashed: wide, flat, medium-deep
      Result.Puffs[np].sy := r*0.65;
      Result.Puffs[np].sz := r;
      Inc(np);
    end;
  end;

  { pale blue-white, soft translucent puffs. msFront so each puff blends its near
    surface ONCE (a double-sided puff would blend front+back and read almost solid);
    opacity 0.55 so the sky and overlapping puffs clearly show through. One squashed
    unit sphere, per-puff scaled; alpha-blended by the engine's transparent pass. }
  mat := TMeshStandardMaterial.Create($f4f8ff);
  mat.Transparent := True; mat.Opacity := 0.55; mat.Side := msFront;
  Result.Inst := TInstancedMesh.Create(TSphereGeometry.Create(1, 10, 8), mat, np);
  scene.Add(Result.Inst);
  DriftClouds(Result, 0);   // initial placement
end;

procedure DriftClouds(cf: TCloudField; dt: Single);
var k: Integer; c: ^TCloud; s: Single; pos, rot, scl: TV3;
begin
  if (cf = nil) or (cf.Inst = nil) then Exit;
  s := cf.Scale;
  if dt <> 0 then
    for k := 0 to High(cf.Clouds) do
    begin
      cf.Clouds[k].drift := cf.Clouds[k].drift + cf.Clouds[k].speed*dt*8;   // *8 ≈ office game dt
      if cf.Clouds[k].baseX + cf.Clouds[k].drift > CLOUD_X then
        cf.Clouds[k].drift := cf.Clouds[k].drift - 2*CLOUD_X;
    end;
  for k := 0 to High(cf.Puffs) do
  begin
    c := @cf.Clouds[cf.Puffs[k].ci];
    pos := V3((c^.baseX + c^.drift + cf.Puffs[k].lx)*s, (c^.y + cf.Puffs[k].ly)*s, (c^.z + cf.Puffs[k].lz)*s);
    rot := V3(0,0,0);
    scl := V3(cf.Puffs[k].sx*s, cf.Puffs[k].sy*s, cf.Puffs[k].sz*s);
    cf.Inst.SetInstance(k, pos, rot, scl);
  end;
end;

procedure TCloudField.Drift(dt: Single); begin DriftClouds(Self, dt); end;

end.
