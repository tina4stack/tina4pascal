unit OfficeScene;

{ A walkable office floor for ThreePascal — floor, perimeter walls, a bullpen of
  desks + chairs, a glass meeting room, reception, plants and a wall clock.
  Built from the same primitives office.js uses, so it reads as the office.
  Feet at y=0; walk it in first person. }

{$mode delphi}{$H+}

interface

uses ThreePascal;

const ROOM_X = 11.5; ROOM_Z = 9.0;      // half-extents for the walk bounds

function BuildOffice: TGroup;

implementation

var
  mDesk, mLeg, mScreen, mFrame, mFloor, mWall, mGlass, mChair,
  mPot, mLeaf, mRecep, mSkin, mBody: TMeshStandardMaterial;

procedure InitMats;
begin
  mDesk  :=TMeshStandardMaterial.Create($9c6b3f); mLeg  :=TMeshStandardMaterial.Create($3a3d55);
  mScreen:=TMeshStandardMaterial.Create($10121f); mFrame:=TMeshStandardMaterial.Create($6a6c90);
  mFloor :=TMeshStandardMaterial.Create($cbc8da); mWall :=TMeshStandardMaterial.Create($e8e7f0);
  mGlass :=TMeshStandardMaterial.Create($9fb4ff); mChair:=TMeshStandardMaterial.Create($2b41e6);
  mPot   :=TMeshStandardMaterial.Create($8a5a34); mLeaf :=TMeshStandardMaterial.Create($3f9d54);
  mRecep :=TMeshStandardMaterial.Create($1d1e38); mSkin :=TMeshStandardMaterial.Create($ffd2a0);
  mBody  :=TMeshStandardMaterial.Create($ff5aa0);
end;

procedure Box(par: TObject3D; w,h,d,x,y,z: Single; m: TMaterial);
var mesh: TMesh;
begin mesh:=TMesh.Create(TBoxGeometry.Create(w,h,d), m); mesh.Position.SetXYZ(x,y,z); par.Add(mesh); end;

procedure Desk(par: TObject3D; x,z,ry: Single);
var g: TGroup;
begin
  g:=TGroup.Create;
  Box(g,1.5,0.06,0.75, 0,0.74,0, mDesk);
  Box(g,0.06,0.74,0.06, -0.68,0.37,-0.32, mLeg); Box(g,0.06,0.74,0.06, 0.68,0.37,-0.32, mLeg);
  Box(g,0.06,0.74,0.06, -0.68,0.37,0.32, mLeg);  Box(g,0.06,0.74,0.06, 0.68,0.37,0.32, mLeg);
  Box(g,0.62,0.4,0.05, 0,1.06,0.30, mScreen); Box(g,0.08,0.16,0.08, 0,0.86,0.30, mLeg);
  Box(g,0.5,0.03,0.16, 0,0.78,-0.08, mFrame);
  g.Position.SetXYZ(x,0,z); g.Rotation.y:=ry; par.Add(g);
end;

procedure Chair(par: TObject3D; x,z,ry: Single);
var g: TGroup; m: TMesh;
begin
  g:=TGroup.Create;
  Box(g,0.5,0.08,0.5, 0,0.48,0, mChair);
  Box(g,0.5,0.55,0.08, 0,0.75,-0.22, mChair);
  m:=TMesh.Create(TCylinderGeometry.Create(0.05,0.05,0.48,8), mLeg); m.Position.SetXYZ(0,0.24,0); g.Add(m);
  g.Position.SetXYZ(x,0,z); g.Rotation.y:=ry; par.Add(g);
end;

procedure Plant(par: TObject3D; x,z: Single);
var pot, leaf: TMesh;
begin
  pot:=TMesh.Create(TCylinderGeometry.Create(0.18,0.22,0.4,10), mPot); pot.Position.SetXYZ(x,0.2,z); par.Add(pot);
  leaf:=TMesh.Create(TIcosahedronGeometry.Create(0.42,0), mLeaf); leaf.Position.SetXYZ(x,0.7,z); leaf.Scale.SetXYZ(1,1.2,1); par.Add(leaf);
end;

procedure Avatar(par: TObject3D; x,z: Single; col: LongWord);
var g: TGroup;
begin
  g:=TGroup.Create;
  Box(g,0.5,0.6,0.28, 0,0.9,0, TMeshStandardMaterial.Create(col));
  Box(g,0.34,0.34,0.34, 0,1.35,0, mSkin);
  g.Position.SetXYZ(x,0,z); par.Add(g);
end;

function BuildOffice: TGroup;
var o: TGroup; clock: TMesh; row, i: Integer;
begin
  InitMats;
  o:=TGroup.Create; o.Name:='office';

  { shell }
  Box(o, 26, 0.2, 22,  0, -0.1, 0, mFloor);
  Box(o, 26, 3.4, 0.3, 0, 1.6, -10.5, mWall);   // back
  Box(o, 26, 3.4, 0.3, 0, 1.6,  10.5, mWall);   // front
  Box(o, 0.3, 3.4, 22, -12.5, 1.6, 0, mWall);   // left
  Box(o, 0.3, 3.4, 22,  12.5, 1.6, 0, mWall);   // right

  { wall clock (torus) }
  clock:=TMesh.Create(TTorusGeometry.Create(0.55,0.09,12,22), mRecep);
  clock.Position.SetXYZ(0,2.4,-10.3); o.Add(clock);

  { bullpen — rows of desks + chairs }
  for row:=0 to 2 do
    for i:=0 to 3 do
    begin
      Desk(o, -4.5 + i*3.0, -4.0 + row*3.2, 0);
      Chair(o, -4.5 + i*3.0, -4.0 + row*3.2 - 0.95, 0);
    end;

  { glass meeting room, back-left corner (frame only) }
  Box(o, 0.12, 3.0, 6.0, -8.5, 1.5, -7.0, mGlass);
  Box(o, 7.0, 3.0, 0.12, -12.0, 1.5, -4.0, mGlass);
  Box(o, 0.12, 0.12, 6.0, -8.5, 3.0, -7.0, mGlass);
  Box(o, 7.0, 0.12, 0.12, -12.0, 3.0, -4.0, mGlass);
  { a meeting table + chairs inside }
  Box(o, 2.4, 0.1, 1.1, -10.4, 0.75, -7.0, mDesk);
  Chair(o, -11.4, -7.0, 1.57); Chair(o, -9.4, -7.0, -1.57);

  { reception desk near the front entrance }
  Box(o, 3.2, 1.05, 0.7, 6.5, 0.52, 7.5, mRecep);
  Box(o, 3.2, 0.1, 0.9, 6.5, 1.05, 7.5, mDesk);
  Avatar(o, 6.5, 8.4, $ffd23c);

  { plants + a couple of seated staff }
  Plant(o, -11.6, 9.2); Plant(o, 11.6, 9.2); Plant(o, 11.6, -9.2);
  Avatar(o, -4.5, -4.0 - 0.95, $ff5aa0);
  Avatar(o, 1.5, -0.8 - 0.95, $4fd18b);

  Result:=o;
end;

end.
