program t3dbox;

{ First ThreePascal render — deliberately written like a three.js snippet to show
  the port fidelity. A lit floor with a few coloured boxes (the office's building
  blocks / graph nodes), rendered in pure software to a bitmap. }

{$mode delphi}{$H+}

uses ThreePascal;

const W = 720; H = 460;
var
  scene: TScene;
  camera: TPerspectiveCamera;
  renderer: TWebGLRenderer;
  floor, cube: TMesh;
  amb: TAmbientLight;
  sun: TDirectionalLight;
begin
  scene := TScene.Create;
  scene.Background.SetHex($0e0f1f);                       // Tina4 --paper (dark)

  camera := TPerspectiveCamera.Create(45, W/H, 0.1, 100);
  camera.Position.SetXYZ(5.5, 4.5, 7.5);
  camera.LookAt(0, 0.6, 0);

  renderer := TWebGLRenderer.Create(W, H);

  amb := TAmbientLight.Create($ffffff, 0.38);  scene.Add(amb);
  sun := TDirectionalLight.Create($ffffff, 0.9); sun.Position.SetXYZ(4, 8, 6); scene.Add(sun);

  { floor slab }
  floor := TMesh.Create(TBoxGeometry.Create(12, 0.3, 12), TMeshStandardMaterial.Create($2a2c4c));
  floor.Position.SetXYZ(0, -0.15, 0);
  scene.Add(floor);

  { three nodes / building blocks in the brand palette }
  cube := TMesh.Create(TBoxGeometry.Create(1.8, 1.8, 1.8), TMeshStandardMaterial.Create($ff5aa0));
  cube.Position.SetXYZ(0, 0.9, 0); cube.Rotation.y := 0.6; scene.Add(cube);

  cube := TMesh.Create(TBoxGeometry.Create(1.2, 1.2, 1.2), TMeshStandardMaterial.Create($2b41e6));
  cube.Position.SetXYZ(3.0, 0.6, -1.2); cube.Rotation.y := -0.3; scene.Add(cube);

  cube := TMesh.Create(TBoxGeometry.Create(1.4, 1.4, 1.4), TMeshStandardMaterial.Create($ffd23c));
  cube.Position.SetXYZ(-2.6, 0.7, 1.4); cube.Rotation.y := 0.9; scene.Add(cube);

  renderer.Render(scene, camera);
  renderer.SaveBMP('/tmp/t3dbox.bmp');
  WriteLn('rendered ', W, 'x', H, ' -> /tmp/t3dbox.bmp');
end.
