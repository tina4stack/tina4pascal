program sheepapp;

{ The Merino ram, walking — written in three.js's pattern: build scene/camera/
  renderer, then an animate() loop driven by RequestAnimationFrame that updates
  the mixer, orbits the camera, and calls renderer.Render. The engine (Tina3D)
  is the "DOM": window, present, input. }

{$mode delphi}{$H+}

uses Math, ThreePascal, RamModel, Tina3D;

const W = 780; H = 540;
var
  scene: TScene; camera: TPerspectiveCamera; renderer: TWebGLRenderer; mixer: TAnimationMixer;
  amb: TAmbientLight; sun: TDirectionalLight; floor: TMesh; sheep: TGroup; gT: Single = 0;

procedure Animate;
begin
  RequestAnimationFrame(@Animate);
  gT := gT + 1/60;
  camera.Position.SetXYZ(Sin(gT*0.5)*2.9, 1.4, Cos(gT*0.5)*2.9);   // slow orbit
  camera.LookAt(0, 0.72, 0);
  mixer.Update(1/60);                                              // walk the ram
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
  floor := TMesh.Create(TPlaneGeometry.Create(30, 30), TMeshStandardMaterial.Create($1b7a3a));
  floor.Rotation.x := -Pi/2; scene.Add(floor);
  sheep := BuildRam; scene.Add(sheep);
  mixer := TAnimationMixer.Create(sheep); mixer.Play(RamWalkClip);

  CreateWindow('Tina4 3D — Walking Ram', W, H, renderer);
  RequestAnimationFrame(@Animate);
  Run;
end.
