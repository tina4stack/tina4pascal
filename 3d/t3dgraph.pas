program t3dgraph;

{ ThreePascal v0.2 capability check — a 3D graph: sphere nodes, line edges, a
  cylinder + cone, a ground plane, a point light and linear fog, smooth-shaded.
  Written like three.js. Pure software render to a bitmap. }

{$mode delphi}{$H+}

uses ThreePascal;

const W = 760; H = 480;
var
  scene: TScene; camera: TPerspectiveCamera; renderer: TWebGLRenderer;
  amb: TAmbientLight; sun: TDirectionalLight; lamp: TPointLight;
  floor, node, cyl, cone: TMesh; edges: TLineSegments; lg: TLineGeometry;
  nodePos: array[0..4] of array[0..2] of Single;
  cols: array[0..4] of LongWord;
  i, j: Integer;
  procedure Connect(a, b: Integer);
  begin lg.Push(nodePos[a][0],nodePos[a][1],nodePos[a][2]);
        lg.Push(nodePos[b][0],nodePos[b][1],nodePos[b][2]); end;
  procedure SetNode(idx: Integer; x, y, z: Single; c: LongWord);
  begin nodePos[idx][0]:=x; nodePos[idx][1]:=y; nodePos[idx][2]:=z; cols[idx]:=c; end;
begin
  scene := TScene.Create;
  scene.Background.SetHex($0e0f1f);
  scene.Fog := TFog.Create($0e0f1f, 9, 26);            // depth fade into the dark

  camera := TPerspectiveCamera.Create(45, W/H, 0.1, 100);
  camera.Position.SetXYZ(7, 6, 10); camera.LookAt(0, 1, 0);

  renderer := TWebGLRenderer.Create(W, H);

  amb  := TAmbientLight.Create($ffffff, 0.32); scene.Add(amb);
  sun  := TDirectionalLight.Create($ffffff, 0.7); sun.Position.SetXYZ(5, 9, 4); scene.Add(sun);
  lamp := TPointLight.Create($ff5aa0, 0.9, 14); lamp.Position.SetXYZ(-3, 3, 2); scene.Add(lamp);

  floor := TMesh.Create(TPlaneGeometry.Create(30, 30), TMeshStandardMaterial.Create($1d1e38));
  floor.Rotation.x := -Pi/2;                           // lay the XY plane flat
  scene.Add(floor);

  SetNode(0,  0.0, 1.4,  0.0, $ff5aa0);
  SetNode(1,  3.0, 1.0, -1.0, $2b41e6);
  SetNode(2, -3.0, 1.2,  1.0, $ffd23c);
  SetNode(3,  1.5, 2.4,  2.0, $7d8cff);
  SetNode(4, -1.5, 0.8, -2.5, $ff7ab4);

  { edges first (behind nodes) }
  lg := TLineGeometry.Create;
  Connect(0,1); Connect(0,2); Connect(0,3); Connect(0,4); Connect(1,3); Connect(2,4);
  edges := TLineSegments.Create(lg, TLineBasicMaterial.Create($6a6c90));
  edges.Material.LineWidth := 2;
  scene.Add(edges);

  { sphere nodes }
  for i := 0 to 4 do
  begin
    node := TMesh.Create(TSphereGeometry.Create(0.5, 20, 14), TMeshStandardMaterial.Create(cols[i]));
    node.Position.SetXYZ(nodePos[i][0], nodePos[i][1], nodePos[i][2]);
    scene.Add(node);
  end;

  { a cylinder + cone off to the side to show those primitives + smooth shading }
  cyl := TMesh.Create(TCylinderGeometry.Create(0.6, 0.6, 2.2, 20), TMeshStandardMaterial.Create($4fd18b));
  cyl.Position.SetXYZ(4.5, 1.1, 3); scene.Add(cyl);
  cone := TMesh.Create(TConeGeometry.Create(0.8, 1.6, 20), TMeshStandardMaterial.Create($f0c256));
  cone.Position.SetXYZ(4.5, 3.1, 3); scene.Add(cone);

  renderer.Render(scene, camera);
  renderer.SaveBMP('/tmp/t3dgraph.bmp');
  WriteLn('rendered ', W, 'x', H, ' -> /tmp/t3dgraph.bmp');
end.
