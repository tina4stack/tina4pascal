program sheepapp;

{ A flock of 20 walking Merino rams under drifting office clouds — written in
  three.js's pattern: build scene/camera/renderer, then an animate() loop driven
  by RequestAnimationFrame that updates each mixer, orbits the camera, drifts the
  clouds, and calls renderer.Render. The engine (Tina3D) is the "DOM". }

{$mode delphi}{$H+}
{$IFDEF WINDOWS}{$apptype gui}{$ENDIF}

uses Math, ThreePascal, RamModel, CloudField, Tina3D;

const W = 780; H = 540; FLOCK = 20;
var
  scene: TScene; camera: TPerspectiveCamera; renderer: TWebGLRenderer;
  amb: TAmbientLight; sun: TDirectionalLight; floor: TMesh; gT: Single = 0;
  clouds: TCloudField;
  sheep: array[0..FLOCK-1] of TGroup;
  mixer: array[0..FLOCK-1] of TAnimationMixer;
  i: Integer;

procedure Animate;
var k: Integer;
begin
  RequestAnimationFrame(@Animate);
  gT := gT + 1/60;
  { slow, wide orbit so the whole flock stays in frame }
  camera.Position.SetXYZ(Sin(gT*0.28)*10.5, 5.4, Cos(gT*0.28)*10.5);
  camera.LookAt(0, 0.6, 0);
  for k := 0 to FLOCK-1 do mixer[k].Update(1/60);   // each ram walks its own phase
  DriftClouds(clouds, 1/60);                         // office puffy clouds drift + wrap
  renderer.Render(scene, camera);
  Present;
end;

begin
  scene := TScene.Create; scene.Background.SetHex($0e0f1f);
  camera := TPerspectiveCamera.Create(45, W/H, 0.05, 100);
  renderer := TWebGLRenderer.Create(W, H, 1);                      // 1x + cheap FXAA edge AA
  renderer.EdgeAA := True;

  amb := TAmbientLight.Create($ffffff, 0.55); scene.Add(amb);
  sun := TDirectionalLight.Create($fff4cf, 0.8); sun.Position.SetXYZ(4, 9, 5); scene.Add(sun);
  floor := TMesh.Create(TPlaneGeometry.Create(40, 40), TMeshStandardMaterial.Create($1b7a3a));
  floor.Rotation.x := -Pi/2; scene.Add(floor);

  { office clouds high over the flock }
  clouds := BuildClouds(scene, 0.05);

  { 20 rams on a 5×4 grid, each turned a little and started at a different point
    in the walk cycle so the flock isn't in lock-step }
  for i := 0 to FLOCK-1 do
  begin
    sheep[i] := BuildRam;
    sheep[i].Position.SetXYZ(((i mod 5) - 2) * 3.2 + Sin(i*1.7)*0.4,
                             0,
                             ((i div 5) - 1.5) * 3.2 + Cos(i*2.1)*0.4);
    sheep[i].Rotation.y := Sin(i*2.3) * 1.4;                       // varied facing
    scene.Add(sheep[i]);
    mixer[i] := TAnimationMixer.Create(sheep[i]); mixer[i].Play(RamWalkClip);
    mixer[i].Update(i * 0.17);                                     // stagger the gait
  end;

  CreateWindow('Tina4 3D — Flock of 20', W, H, renderer);
  RequestAnimationFrame(@Animate);
  Run;
end.
