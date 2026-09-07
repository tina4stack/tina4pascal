program t3dlabel;

{ Sprites + text labels — a 3D graph where each node carries a billboard label
  (MakeLabel → texture with the built-in font → camera-facing sprite). Proves
  Sprite/SpriteMaterial/TTexture + the font. Pure software render. }

{$mode delphi}{$H+}

uses SysUtils, ThreePascal;

const W = 820; H = 520;
var
  scene: TScene; camera: TPerspectiveCamera; renderer: TWebGLRenderer;
  amb: TAmbientLight; sun: TDirectionalLight;
  floor, nodeM: TMesh; edges: TLineSegments; lg: TLineGeometry;
  lbl: TSprite; dot: TSprite;
  npos: array[0..4] of TV3; cols: array[0..4] of LongWord;
  names: array[0..4] of string;
  i: Integer;
  procedure Conn(a, b: Integer); begin lg.PushV(npos[a]); lg.PushV(npos[b]); end;
begin
  scene := TScene.Create; scene.Background.SetHex($0e0f1f);
  camera := TPerspectiveCamera.Create(45, W/H, 0.1, 100);
  camera.Position.SetXYZ(6.5, 5.5, 10); camera.LookAt(0, 1.2, 0);
  renderer := TWebGLRenderer.Create(W, H);

  amb := TAmbientLight.Create($ffffff, 0.4); scene.Add(amb);
  sun := TDirectionalLight.Create($ffffff, 0.75); sun.Position.SetXYZ(5, 9, 4); scene.Add(sun);

  floor := TMesh.Create(TPlaneGeometry.Create(30, 30), TMeshStandardMaterial.Create($1d1e38));
  floor.Rotation.x := -Pi/2; scene.Add(floor);

  npos[0]:=V3(0,1.3,0);   cols[0]:=$ff5aa0; names[0]:='ALICE';
  npos[1]:=V3(3.2,1.0,-1);cols[1]:=$2b41e6; names[1]:='BOB';
  npos[2]:=V3(-3,1.2,1);  cols[2]:=$ffd23c; names[2]:='CAROL';
  npos[3]:=V3(1.4,2.5,2); cols[3]:=$4fd18b; names[3]:='DAN';
  npos[4]:=V3(-1.6,0.9,-2.6); cols[4]:=$ff7ab4; names[4]:='EVE';

  lg := TLineGeometry.Create;
  Conn(0,1); Conn(0,2); Conn(0,3); Conn(0,4); Conn(1,3);
  edges := TLineSegments.Create(lg, TLineBasicMaterial.Create($6a6c90));
  edges.Material.LineWidth := 2; scene.Add(edges);

  for i := 0 to 4 do
  begin
    nodeM := TMesh.Create(TSphereGeometry.Create(0.5, 20, 14), TMeshStandardMaterial.Create(cols[i]));
    nodeM.Position.SetXYZ(npos[i].x, npos[i].y, npos[i].z); scene.Add(nodeM);
    { floating label above each node }
    lbl := MakeLabel(names[i], 2, $ffffff, $16172c, 220);
    lbl.Position.SetXYZ(npos[i].x, npos[i].y + 0.9, npos[i].z);
    lbl.Scale.MultiplyScalar(0.7);                   // trim the default world size
    scene.Add(lbl);
  end;

  { a plain solid-colour sprite (no texture) to show SpriteMaterial colour }
  dot := TSprite.Create(TSpriteMaterial.Create(nil, $ffd23c));
  dot.Position.SetXYZ(0, 3.4, 0); dot.Scale.SetXYZ(0.25, 0.25, 1);
  scene.Add(dot);

  renderer.Render(scene, camera);
  renderer.SaveBMP('/tmp/t3dlabel.bmp');
  WriteLn('rendered ', W, 'x', H, ' -> /tmp/t3dlabel.bmp');
end.
