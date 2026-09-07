program t3dpick;

{ Raycaster proof — build a 3D graph, then pick with rays two ways:
    1. SetRay: aim straight at a known node, confirm it's the one returned.
    2. SetFromCamera(ndc): unproject a screen point into a ray, see what it hits.
  The picked node is recoloured white and a marker dropped at the hit point, so
  the render visually confirms what the printout reports. }

{$mode delphi}{$H+}

uses SysUtils, ThreePascal;

const W = 760; H = 480;
var
  scene: TScene; camera: TPerspectiveCamera; renderer: TWebGLRenderer;
  amb: TAmbientLight; sun: TDirectionalLight;
  floor, marker: TMesh; edges: TLineSegments; lg: TLineGeometry;
  node: array[0..4] of TMesh;
  npos: array[0..4] of TV3;
  cols: array[0..4] of LongWord;
  ray: TRaycaster; hit: TIntersection;
  i: Integer;
  procedure Conn(a, b: Integer);
  begin lg.PushV(npos[a]); lg.PushV(npos[b]); end;
begin
  scene := TScene.Create; scene.Background.SetHex($0e0f1f);
  camera := TPerspectiveCamera.Create(45, W/H, 0.1, 100);
  camera.Position.SetXYZ(7, 6, 10); camera.LookAt(0, 1, 0);
  renderer := TWebGLRenderer.Create(W, H);

  amb := TAmbientLight.Create($ffffff, 0.35); scene.Add(amb);
  sun := TDirectionalLight.Create($ffffff, 0.8); sun.Position.SetXYZ(5, 9, 4); scene.Add(sun);

  floor := TMesh.Create(TPlaneGeometry.Create(30, 30), TMeshStandardMaterial.Create($1d1e38));
  floor.Rotation.x := -Pi/2; floor.Name := 'floor'; scene.Add(floor);

  npos[0]:=V3(0,1.4,0);   cols[0]:=$ff5aa0;
  npos[1]:=V3(3,1.0,-1);  cols[1]:=$2b41e6;
  npos[2]:=V3(-3,1.2,1);  cols[2]:=$ffd23c;
  npos[3]:=V3(1.5,2.4,2); cols[3]:=$7d8cff;
  npos[4]:=V3(-1.5,0.8,-2.5); cols[4]:=$ff7ab4;

  lg := TLineGeometry.Create;
  Conn(0,1); Conn(0,2); Conn(0,3); Conn(0,4);
  edges := TLineSegments.Create(lg, TLineBasicMaterial.Create($6a6c90));
  edges.Material.LineWidth := 2; scene.Add(edges);

  for i := 0 to 4 do
  begin
    node[i] := TMesh.Create(TSphereGeometry.Create(0.5, 20, 14), TMeshStandardMaterial.Create(cols[i]));
    node[i].Position.SetXYZ(npos[i].x, npos[i].y, npos[i].z);
    node[i].Name := 'node' + IntToStr(i);
    scene.Add(node[i]);
  end;

  ray := TRaycaster.Create;

  { --- Test 1: aim a ray straight at node 2 --- }
  ray.SetRay(camera.Position.V,
    V3(npos[2].x - camera.Position.x, npos[2].y - camera.Position.y, npos[2].z - camera.Position.z));
  hit := ray.IntersectObject(scene, True);
  if hit.Hit then
    WriteLn(Format('SetRay→node2: hit "%s" at dist %.2f, point (%.2f, %.2f, %.2f)',
      [hit.Obj.Name, hit.Distance, hit.Point.x, hit.Point.y, hit.Point.z]))
  else WriteLn('SetRay→node2: MISS');

  { --- Test 2: unproject screen centre (NDC 0,0) into a ray --- }
  ray.SetFromCamera(0.0, 0.0, camera);
  hit := ray.IntersectObject(scene, True);
  if hit.Hit then
  begin
    WriteLn(Format('SetFromCamera(0,0): hit "%s" at dist %.2f, point (%.2f, %.2f, %.2f)',
      [hit.Obj.Name, hit.Distance, hit.Point.x, hit.Point.y, hit.Point.z]));
    { highlight the picked object white + drop a marker at the hit point }
    if hit.Obj is TMesh then TMesh(hit.Obj).Material.Color.SetHex($ffffff);
    marker := TMesh.Create(TSphereGeometry.Create(0.14, 10, 8), TMeshBasicMaterial.Create($ff2d2d));
    marker.Position.SetXYZ(hit.Point.x, hit.Point.y, hit.Point.z); scene.Add(marker);
  end
  else WriteLn('SetFromCamera(0,0): MISS');

  renderer.Render(scene, camera);
  renderer.SaveBMP('/tmp/t3dpick.bmp');
  WriteLn('rendered ', W, 'x', H, ' -> /tmp/t3dpick.bmp');
end.
