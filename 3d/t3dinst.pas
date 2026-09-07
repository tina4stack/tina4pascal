program t3dinst;

{ InstancedMesh — one box geometry drawn many times with per-instance transforms
  (three.InstancedMesh + setMatrixAt). A grid of towers whose height ripples from
  the centre. This is exactly how the office batches its chairs. Pure software. }

{$mode delphi}{$H+}

uses SysUtils, ThreePascal;

const W = 840; H = 520; N = 16;          // N x N instances
var
  scene: TScene; camera: TPerspectiveCamera; renderer: TWebGLRenderer;
  amb: TAmbientLight; sun: TDirectionalLight;
  floor: TMesh; towers: TInstancedMesh;
  gx, gz, i: Integer; x, z, d, hgt: Single;
begin
  scene := TScene.Create; scene.Background.SetHex($0e0f1f);
  scene.Fog := TFog.Create($0e0f1f, 14, 40);

  camera := TPerspectiveCamera.Create(45, W/H, 0.1, 100);
  camera.Position.SetXYZ(13, 11, 15); camera.LookAt(0, 0.5, 0);
  renderer := TWebGLRenderer.Create(W, H);

  amb := TAmbientLight.Create($ffffff, 0.4); scene.Add(amb);
  sun := TDirectionalLight.Create($fff4cf, 0.8); sun.Position.SetXYZ(6, 12, 5); scene.Add(sun);

  floor := TMesh.Create(TPlaneGeometry.Create(40, 40), TMeshStandardMaterial.Create($16172c));
  floor.Rotation.x := -Pi/2; scene.Add(floor);

  { one geometry + one material, N*N instances }
  towers := TInstancedMesh.Create(TBoxGeometry.Create(0.7, 1, 0.7),
                                  TMeshStandardMaterial.Create($2b41e6), N*N);
  i := 0;
  for gx := 0 to N-1 do
    for gz := 0 to N-1 do
    begin
      x := (gx - (N-1)/2) * 0.95;
      z := (gz - (N-1)/2) * 0.95;
      d := Sqrt(x*x + z*z);
      hgt := 0.6 + 2.6 * (0.5 + 0.5*Cos(d*0.9));      // height ripples from centre
      towers.SetInstance(i, V3(x, hgt/2, z), V3(0, d*0.15, 0), V3(1, hgt, 1));
      Inc(i);
    end;
  scene.Add(towers);

  renderer.Render(scene, camera);
  renderer.SaveBMP('/tmp/t3dinst.bmp');
  WriteLn('rendered ', N*N, ' instances -> /tmp/t3dinst.bmp');
end.
