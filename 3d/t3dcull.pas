program t3dcull;

{ Regression guard for backface culling (material.Side = msFront, three.js
  FrontSide). Every built-in closed primitive must be OPAQUE where its near
  surface faces the camera: a centred instance in front of a magenta ground,
  sampled on its front surface, must read the lit material colour — never the
  background. A background reading means FrontSide culled the NEAR faces and
  revealed the interior = inward winding (the bug that made cylinders/cones —
  and so the ram's horns — render "transparent"). Exit code 1 on any failure.

  Run: fpc -Mdelphi -Fu. t3dcull.pas && ./t3dcull }

{$mode delphi}{$H+}

uses SysUtils, ThreePascal;

const W = 200; H = 200; BG = $ff00ff;   // magenta ground truth
var pass: Boolean = True;

  { render one primitive with msFront, sample pixel (sx,sy) — must be opaque }
  procedure Check(const nm: string; geo: TBufferGeometry; sx, sy: Integer);
  var scene: TScene; cam: TPerspectiveCamera; rend: TWebGLRenderer;
      mat: TMeshStandardMaterial; ci, r, g, b: Integer; bad: Boolean;
  begin
    scene := TScene.Create; scene.Background.SetHex(BG);
    cam := TPerspectiveCamera.Create(45, 1, 0.05, 100);
    cam.Position.SetXYZ(0, 0, 3); cam.LookAt(0, 0, 0);
    scene.Add(TAmbientLight.Create($ffffff, 1.0));
    mat := TMeshStandardMaterial.Create($3366ff); mat.Side := msFront;
    scene.Add(TMesh.Create(geo, mat));
    rend := TWebGLRenderer.Create(W, H, 1);
    rend.Render(scene, cam);
    ci := (sy*W + sx)*4;
    r := rend.Pixels[ci]; g := rend.Pixels[ci+1]; b := rend.Pixels[ci+2];
    bad := (r > 180) and (g < 80) and (b > 180);        // still magenta = see-through
    WriteLn(Format('  %-12s rgb=(%3d,%3d,%3d)  %s',
      [nm, r, g, b, BoolToStr(not bad, 'OPAQUE', 'TRANSPARENT *** BUG')]));
    if bad then pass := False;
    rend.Free; scene.Free;
  end;

begin
  WriteLn('msFront (FrontSide) opacity — near face must be lit, not background:');
  Check('Box',         TBoxGeometry.Create(1.6, 1.6, 1.6),        W div 2, H div 2);
  Check('Sphere',      TSphereGeometry.Create(1.0, 16, 12),       W div 2, H div 2);
  Check('Cylinder',    TCylinderGeometry.Create(0.8, 0.8, 1.8, 12), W div 2, H div 2);
  Check('Cone',        TConeGeometry.Create(1.0, 1.8, 12),        W div 2, H div 2);
  Check('Torus',       TTorusGeometry.Create(0.8, 0.35, 16, 10),  164, H div 2);  // ring, not the hole
  Check('Icosahedron', TIcosahedronGeometry.Create(1.1, 0),       W div 2, H div 2);
  WriteLn;
  if pass then WriteLn('ALL PASS — msFront matches three.js FrontSide')
  else begin WriteLn('FAIL — a primitive is inward-wound'); Halt(1); end;
end.
