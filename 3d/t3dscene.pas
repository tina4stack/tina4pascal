program t3dscene;

{ Phase 7 compositing — the <scene> embed model in one frame: a 3D office
  rendered by ThreePascal as the BASE layer, then a Tina4-styled HUD composited
  ON TOP (panels + text via the overlay primitives) — the role the HTML layer
  plays in a shell. A wall clock uses TorusGeometry (new). Pure software. }

{$mode delphi}{$H+}

uses SysUtils, ThreePascal;

const W = 900; H = 560;
var
  scene: TScene; camera: TPerspectiveCamera; renderer: TWebGLRenderer;
  amb: TAmbientLight; sun: TDirectionalLight; lamp: TPointLight;
  chairs: TInstancedMesh;
  mDesk, mLeg, mScreen, mFrame, mFloor, mWall, mSkin, mBody: TMeshStandardMaterial;
  clock: TMesh;
  row, i: Integer;

  procedure Box(par: TObject3D; w,h,d,x,y,z: Single; m: TMaterial);
  var mesh: TMesh; begin
    mesh:=TMesh.Create(TBoxGeometry.Create(w,h,d), m); mesh.Position.SetXYZ(x,y,z); par.Add(mesh);
  end;
  procedure Desk(x,z,ry: Single);
  var g: TGroup; begin
    g:=TGroup.Create;
    Box(g,1.5,0.06,0.75, 0,0.74,0, mDesk);
    Box(g,0.06,0.74,0.06, -0.68,0.37,-0.32, mLeg); Box(g,0.06,0.74,0.06, 0.68,0.37,-0.32, mLeg);
    Box(g,0.06,0.74,0.06, -0.68,0.37,0.32, mLeg);  Box(g,0.06,0.74,0.06, 0.68,0.37,0.32, mLeg);
    Box(g,0.62,0.4,0.05, 0,1.06,0.30, mScreen); Box(g,0.5,0.03,0.16, 0,0.78,-0.08, mFrame);
    g.Position.SetXYZ(x,0,z); g.Rotation.y:=ry; scene.Add(g);
  end;
  procedure Avatar(x,z: Single; col: LongWord);
  var g: TGroup; bod: TMeshStandardMaterial; begin
    g:=TGroup.Create; bod:=TMeshStandardMaterial.Create(col);
    Box(g,0.5,0.8,0.28, 0,1.05,0, bod);
    Box(g,0.34,0.34,0.34, 0,1.62,0, mSkin);
    Box(g,0.17,0.72,0.17, -0.14,0.36,0, mLeg); Box(g,0.17,0.72,0.17, 0.14,0.36,0, mLeg);
    Box(g,0.13,0.6,0.13, -0.33,1.05,0, bod);   Box(g,0.13,0.6,0.13, 0.33,1.05,0, bod);
    g.Position.SetXYZ(x,0,z); scene.Add(g);
  end;

begin
  scene:=TScene.Create; scene.Background.SetHex($0e0f1f);
  camera:=TPerspectiveCamera.Create(52, W/H, 0.05, 100);
  camera.Position.SetXYZ(4.6, 3.0, 6.2); camera.LookAt(-0.5, 1.1, -1.0);
  renderer:=TWebGLRenderer.Create(W, H);

  amb:=TAmbientLight.Create($ffffff, 0.5); scene.Add(amb);
  sun:=TDirectionalLight.Create($fff4cf, 0.7); sun.Position.SetXYZ(5,10,4); scene.Add(sun);
  lamp:=TPointLight.Create($ff5aa0, 0.5, 16); lamp.Position.SetXYZ(-4,3,-3); scene.Add(lamp);

  mDesk:=TMeshStandardMaterial.Create($9c6b3f); mLeg:=TMeshStandardMaterial.Create($3a3d55);
  mScreen:=TMeshStandardMaterial.Create($10121f); mFrame:=TMeshStandardMaterial.Create($6a6c90);
  mFloor:=TMeshStandardMaterial.Create($c9c6d8); mWall:=TMeshStandardMaterial.Create($e6e5f0);
  mSkin:=TMeshStandardMaterial.Create($ffd2a0); mBody:=TMeshStandardMaterial.Create($2b41e6);

  Box(scene,16,0.2,12, 0,-0.1,0, mFloor);
  Box(scene,16,3.2,0.2, 0,1.5,-6, mWall);
  Box(scene,0.2,3.2,12, -8,1.5,0, mWall);

  { a wall clock — TorusGeometry (new in phase 6) }
  clock:=TMesh.Create(TTorusGeometry.Create(0.5,0.08,10,20), TMeshStandardMaterial.Create($15162e));
  clock.Position.SetXYZ(-3,2.2,-5.85); scene.Add(clock);

  for row:=0 to 1 do
    for i:=0 to 2 do Desk(-2.4+i*2.4, 0.5+row*3.0, 0);

  { chairs — one InstancedMesh batch }
  chairs:=TInstancedMesh.Create(TBoxGeometry.Create(0.5,0.08,0.5), TMeshStandardMaterial.Create($2b41e6), 6);
  i:=0;
  for row:=0 to 1 do begin
    chairs.SetInstance(i, V3(-2.4, 0.48, 0.5+row*3.0-0.9), V3(0,0,0), V3(1,1,1)); Inc(i);
    chairs.SetInstance(i, V3(0.0,  0.48, 0.5+row*3.0-0.9), V3(0,0,0), V3(1,1,1)); Inc(i);
    chairs.SetInstance(i, V3(2.4,  0.48, 0.5+row*3.0-0.9), V3(0,0,0), V3(1,1,1)); Inc(i);
  end;
  scene.Add(chairs);

  Avatar(-2.4, -0.6, $ff5aa0);
  Avatar(0.2, 2.0, $ffd23c);

  { ---- BASE LAYER: render the 3D ---- }
  renderer.Render(scene, camera);

  { ---- OVERLAY LAYER: the HUD, composited on top (the HTML layer's role) ---- }
  // top bar
  renderer.FillRectPx(0, 0, W, 46, 14,15,31, 0.78);
  renderer.FillRectPx(0, 46, W, 2, 43,65,230, 0.9);
  renderer.DrawTextPx(18, 15, 'VIRTUAL OFFICE', 3, 255,255,255);
  renderer.FillRectPx(W-150, 17, 12, 12, 79,209,139, 1.0);          // green dot
  renderer.DrawTextPx(W-128, 16, '5 ONLINE', 2, 236,236,251);
  // presenting pill (pink)
  renderer.FillRectPx(W-150, 60, 134, 26, 255,90,160, 0.9);
  renderer.DrawTextPx(W-140, 66, 'LIVE CALL', 2, 255,255,255);
  // roster panel
  renderer.FillRectPx(16, 62, 176, 158, 22,23,44, 0.72);
  renderer.StrokeRectPx(16, 62, 176, 158, 1, 79,141,255, 0.5);
  renderer.DrawTextPx(28, 72, 'ROSTER', 2, 150,152,180);
  renderer.FillRectPx(28, 96,  10,10, 255,90,160,1);  renderer.DrawTextPx(46, 95, 'ALICE', 2, 236,236,251);
  renderer.FillRectPx(28, 118, 10,10, 43,65,230,1);   renderer.DrawTextPx(46, 117,'BOB', 2, 236,236,251);
  renderer.FillRectPx(28, 140, 10,10, 255,210,60,1);  renderer.DrawTextPx(46, 139,'CAROL', 2, 236,236,251);
  renderer.FillRectPx(28, 162, 10,10, 79,209,139,1);  renderer.DrawTextPx(46, 161,'DAN', 2, 236,236,251);
  renderer.FillRectPx(28, 184, 10,10, 255,122,180,1); renderer.DrawTextPx(46, 183,'EVE', 2, 236,236,251);
  // chat line
  renderer.FillRectPx(16, H-40, 320, 26, 22,23,44, 0.7);
  renderer.DrawTextPx(26, H-34, 'ALICE: HELLO TEAM', 2, 200,201,224);
  // crosshair
  renderer.FillRectPx(W div 2 - 8, H div 2 - 1, 16, 2, 255,255,255, 0.7);
  renderer.FillRectPx(W div 2 - 1, H div 2 - 8, 2, 16, 255,255,255, 0.7);

  renderer.SaveBMP('/tmp/t3dscene.bmp');
  WriteLn('rendered composited office -> /tmp/t3dscene.bmp');
end.
