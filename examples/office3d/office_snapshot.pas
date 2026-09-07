program office_snapshot;
{$mode delphi}{$H+}
uses ThreePascal, OfficeScene;
const W=900; H=600;
var scene: TScene; cam: TPerspectiveCamera; r: TWebGLRenderer;
    amb: TAmbientLight; sun: TDirectionalLight; lamp: TPointLight;
begin
  scene:=TScene.Create; scene.Background.SetHex($0e0f1f); scene.Fog:=TFog.Create($0e0f1f,22,46);
  cam:=TPerspectiveCamera.Create(60, W/H, 0.05, 100);
  cam.Position.SetXYZ(6.5, 2.2, 8.2); cam.LookAt(-3, 1.0, -3);
  r:=TWebGLRenderer.Create(W,H,2);
  amb:=TAmbientLight.Create($ffffff,0.6); scene.Add(amb);
  sun:=TDirectionalLight.Create($fff4cf,0.55); sun.Position.SetXYZ(6,12,4); scene.Add(sun);
  lamp:=TPointLight.Create($aac0ff,0.5,20); lamp.Position.SetXYZ(0,3,0); scene.Add(lamp);
  scene.Add(BuildOffice);
  r.Render(scene, cam); r.SaveBMP('/tmp/office.bmp');
  WriteLn('office -> /tmp/office.bmp');
end.
