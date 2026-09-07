program officeapp;

{ Walk the office — three.js pattern: build scene/camera/renderer, then an
  animate() loop driven by RequestAnimationFrame that runs WalkControls (the
  engine's PointerLockControls analogue) and calls renderer.Render. Tina3D is
  the "DOM": window, GPU present, input. No logins, no video. }

{$mode delphi}{$H+}

uses Math, ThreePascal, OfficeScene, Tina3D;

const W = 900; H = 600;
var
  scene: TScene; camera: TPerspectiveCamera; renderer: TWebGLRenderer;
  amb: TAmbientLight; sun: TDirectionalLight; lamp: TPointLight;

procedure Animate;
begin
  RequestAnimationFrame(@Animate);
  WalkControls(camera, ROOM_X, ROOM_Z);           // WASD + pointer-locked mouse-look
  renderer.Render(scene, camera);
  Present;
end;

begin
  scene := TScene.Create; scene.Background.SetHex($0e0f1f);
  scene.Fog := TFog.Create($0e0f1f, 22, 46);
  camera := TPerspectiveCamera.Create(60, W/H, 0.05, 100);
  camera.Position.SetXYZ(0, 1.55, 8);
  renderer := TWebGLRenderer.Create(W, H, 1);       // 1x for a smooth walk; X toggles AA

  amb := TAmbientLight.Create($ffffff, 0.6); scene.Add(amb);
  sun := TDirectionalLight.Create($fff4cf, 0.55); sun.Position.SetXYZ(6, 12, 4); scene.Add(sun);
  lamp := TPointLight.Create($aac0ff, 0.5, 20); lamp.Position.SetXYZ(0, 3, 0); scene.Add(lamp);
  scene.Add(BuildOffice);

  CreateWindow('Tina4 3D — Walkable Office', W, H, renderer);
  PointerLock;
  RequestAnimationFrame(@Animate);
  Run;
end.
