program t3doffice;

{ First slice of the native office — makeDesk() and chair() ported almost
  line-for-line from office.js to ThreePascal, assembled into a room (floor,
  walls, desks, chairs, a glass meeting-room frame). Pure-software render.
  This proves the office code ports mechanically onto the three.js-shaped API. }

{$mode delphi}{$H+}

uses ThreePascal;

const W = 900; H = 540;
var
  scene: TScene; camera: TPerspectiveCamera; renderer: TWebGLRenderer;
  amb: TAmbientLight; sun: TDirectionalLight; lamp: TPointLight;
  { mat.* — the office material palette }
  matDesk, matDeskLeg, matScreen, matFrame, matChair, matWood,
  matFloor, matWall, matGlass: TMeshStandardMaterial;

procedure Box(scene: TObject3D; w, h, d, x, y, z: Single; m: TMeshStandardMaterial);
var mesh: TMesh;
begin
  mesh := TMesh.Create(TBoxGeometry.Create(w, h, d), m);
  mesh.Position.SetXYZ(x, y, z); scene.Add(mesh);
end;

{ ported: makeDesk(THREE, scene, mat, x, z, y, ry) }
procedure MakeDesk(scene: TObject3D; x, z, y, ry: Single);
var g: TGroup; top, leg, mon, stand, kb: TMesh; i: Integer;
  lx: array[0..3] of Single; lz: array[0..3] of Single;
begin
  lx[0]:=-0.68; lz[0]:=-0.32; lx[1]:=0.68; lz[1]:=-0.32;
  lx[2]:=-0.68; lz[2]:= 0.32; lx[3]:=0.68; lz[3]:= 0.32;
  g := TGroup.Create;
  top := TMesh.Create(TBoxGeometry.Create(1.5, 0.06, 0.75), matDesk); top.Position.y := 0.74; g.Add(top);
  for i := 0 to 3 do
  begin
    leg := TMesh.Create(TBoxGeometry.Create(0.06, 0.74, 0.06), matDeskLeg);
    leg.Position.SetXYZ(lx[i], 0.37, lz[i]); g.Add(leg);
  end;
  mon   := TMesh.Create(TBoxGeometry.Create(0.62, 0.4, 0.05), matScreen);  mon.Position.SetXYZ(0, 1.06, 0.3);   g.Add(mon);
  stand := TMesh.Create(TBoxGeometry.Create(0.08, 0.16, 0.08), matDeskLeg); stand.Position.SetXYZ(0, 0.86, 0.3); g.Add(stand);
  kb    := TMesh.Create(TBoxGeometry.Create(0.5, 0.03, 0.16), matFrame);   kb.Position.SetXYZ(0, 0.78, -0.08);  g.Add(kb);
  g.Position.SetXYZ(x, y, z); g.Rotation.y := ry; scene.Add(g);
end;

{ ported: chair(THREE, scene, mat, x, z, y, ry) }
procedure MakeChair(scene: TObject3D; x, z, y, ry: Single);
var g: TGroup; seat, back, post: TMesh;
begin
  g := TGroup.Create;
  seat := TMesh.Create(TBoxGeometry.Create(0.5, 0.08, 0.5), matChair); seat.Position.y := 0.48; g.Add(seat);
  back := TMesh.Create(TBoxGeometry.Create(0.5, 0.55, 0.08), matChair); back.Position.SetXYZ(0, 0.75, -0.22); g.Add(back);
  post := TMesh.Create(TCylinderGeometry.Create(0.05, 0.05, 0.48, 8), matDeskLeg); post.Position.y := 0.24; g.Add(post);
  g.Position.SetXYZ(x, y, z); g.Rotation.y := ry; scene.Add(g);
end;

var row, col: Integer; dx, dz: Single;
begin
  scene := TScene.Create;
  scene.Background.SetHex($0e0f1f);

  camera := TPerspectiveCamera.Create(50, W/H, 0.1, 100);
  camera.Position.SetXYZ(7.5, 5.2, 8.5); camera.LookAt(0, 0.9, -0.5);

  renderer := TWebGLRenderer.Create(W, H);

  // the office material palette (mat.*)
  matDesk    := TMeshStandardMaterial.Create($9c6b3f);   // wood desktop
  matDeskLeg := TMeshStandardMaterial.Create($3a3d55);   // dark legs
  matScreen  := TMeshStandardMaterial.Create($10121f);   // monitor
  matFrame   := TMeshStandardMaterial.Create($6a6c90);   // keyboard/frame
  matChair   := TMeshStandardMaterial.Create($2b41e6);   // brand-blue chairs
  matWood    := TMeshStandardMaterial.Create($8a5a34);
  matFloor   := TMeshStandardMaterial.Create($c9c6d8);   // light floor
  matWall    := TMeshStandardMaterial.Create($e6e5f0);   // light walls
  matGlass   := TMeshStandardMaterial.Create($7d8cff);   // meeting-room glass frame

  amb := TAmbientLight.Create($ffffff, 0.5); scene.Add(amb);
  sun := TDirectionalLight.Create($fff4cf, 0.75); sun.Position.SetXYZ(6, 10, 4); scene.Add(sun);
  lamp := TPointLight.Create($ffd23c, 0.5, 18); lamp.Position.SetXYZ(-4, 3.2, -3); scene.Add(lamp);

  { room: floor + four perimeter walls }
  Box(scene, 16, 0.2, 12,  0, -0.1, 0, matFloor);
  Box(scene, 16, 3.0, 0.2, 0, 1.4, -6, matWall);     // back
  Box(scene, 0.2, 3.0, 12, -8, 1.4, 0, matWall);     // left
  Box(scene, 0.2, 3.0, 12,  8, 1.4, 0, matWall);     // right

  { a glass meeting room in the back-left corner (frame only) }
  Box(scene, 0.12, 2.6, 4.0, -4.0, 1.3, -4.0, matGlass);
  Box(scene, 4.0, 2.6, 0.12, -6.0, 1.3, -2.0, matGlass);
  Box(scene, 4.0, 0.12, 4.0, -4.0, 2.6, -4.0, matGlass);

  { two rows of desks + chairs (the bullpen) }
  for row := 0 to 1 do
    for col := 0 to 2 do
    begin
      dx := -2.4 + col * 2.4;
      dz := 0.5 + row * 3.0;
      MakeDesk(scene, dx, dz, 0, 0);
      MakeChair(scene, dx, dz - 0.9, 0, 0);   // seated on the -z side
    end;

  renderer.Render(scene, camera);
  renderer.SaveBMP('/tmp/t3doffice.bmp');
  WriteLn('rendered ', W, 'x', H, ' -> /tmp/t3doffice.bmp');
end.
