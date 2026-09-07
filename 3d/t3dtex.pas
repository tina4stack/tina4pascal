program t3dtex;

{ Textures — UV-mapped meshes sampling a TTexture. A "presentation screen" (an
  unlit textured plane, like the office's in-world screens — later fed live
  camera frames as a VideoTexture) and a lit textured crate. Pure software. }

{$mode delphi}{$H+}

uses SysUtils, ThreePascal;

const W = 820; H = 500;
var
  scene: TScene; camera: TPerspectiveCamera; renderer: TWebGLRenderer;
  amb: TAmbientLight; sun: TDirectionalLight;
  floor, screen, crate: TMesh;
  scrTex, crateTex: TTexture;
  scrMat: TMeshBasicMaterial; crateMat: TMeshStandardMaterial;
  x, y: Integer;
begin
  scene := TScene.Create; scene.Background.SetHex($0e0f1f);
  camera := TPerspectiveCamera.Create(45, W/H, 0.1, 100);
  camera.Position.SetXYZ(0.5, 2.4, 7); camera.LookAt(0, 1.6, 0);
  renderer := TWebGLRenderer.Create(W, H);

  amb := TAmbientLight.Create($ffffff, 0.45); scene.Add(amb);
  sun := TDirectionalLight.Create($fff4cf, 0.8); sun.Position.SetXYZ(4, 8, 6); scene.Add(sun);

  floor := TMesh.Create(TPlaneGeometry.Create(24, 24), TMeshStandardMaterial.Create($16172c));
  floor.Rotation.x := -Pi/2; scene.Add(floor);

  { --- build a "screen" texture: gradient + brand bar + text --- }
  scrTex := TTexture.Create(360, 216);
  for y := 0 to scrTex.Height-1 do
    for x := 0 to scrTex.Width-1 do
      scrTex.SetPixel(x, y, 14 + (x*40) div scrTex.Width, 15 + (y*60) div scrTex.Height, 31 + (y*120) div scrTex.Height, 255);
  for y := 0 to 7 do for x := 0 to scrTex.Width-1 do scrTex.SetPixel(x, y, 43, 65, 230, 255);        // top bar
  for y := 0 to 5 do for x := 0 to scrTex.Width-1 do scrTex.SetPixel(x, scrTex.Height-1-y, 255, 90, 160, 255); // bottom
  scrTex.DrawText('TINA4 LIVE', 24, 60, 5, 255, 255, 255, 255);
  scrTex.DrawText('SOFTWARE 3D', 24, 120, 3, 125, 140, 255, 255);
  scrTex.DrawText('NO GPU', 24, 156, 3, 255, 210, 60, 255);

  scrMat := TMeshBasicMaterial.Create($ffffff);   // unlit — a screen emits
  scrMat.Map := scrTex;
  screen := TMesh.Create(TPlaneGeometry.Create(4.0, 2.4), scrMat);
  screen.Position.SetXYZ(-1.2, 1.7, 0);            // upright, +Z faces the camera
  scene.Add(screen);

  { --- a textured crate (box UVs, lit) --- }
  crateTex := TTexture.Create(128, 128);
  crateTex.Fill(150, 105, 60, 255);
  for x := 0 to 127 do begin crateTex.SetPixel(x,0,60,40,20,255); crateTex.SetPixel(x,127,60,40,20,255); end;
  for y := 0 to 127 do begin crateTex.SetPixel(0,y,60,40,20,255); crateTex.SetPixel(127,y,60,40,20,255); end;
  for y := 60 to 68 do for x := 8 to 119 do crateTex.SetPixel(x,y,90,60,35,255);   // plank line
  crateTex.DrawText('BOX', 34, 44, 5, 40, 25, 12, 255);

  crateMat := TMeshStandardMaterial.Create($ffffff);
  crateMat.Map := crateTex;
  crate := TMesh.Create(TBoxGeometry.Create(1.8, 1.8, 1.8), crateMat);
  crate.Position.SetXYZ(2.4, 0.9, 0.3); crate.Rotation.y := -0.5; scene.Add(crate);

  renderer.Render(scene, camera);
  renderer.SaveBMP('/tmp/t3dtex.bmp');
  WriteLn('rendered ', W, 'x', H, ' -> /tmp/t3dtex.bmp');
end.
