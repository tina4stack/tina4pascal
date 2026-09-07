program t3dgltf;

{ GLTFLoader — load one of the office's ship .glb files and render it. Auto-frames
  by computing the model's bounds. Pure software render. }

{$mode delphi}{$H+}

uses SysUtils, ThreePascal, ThreePascalGLTF;

const W = 820; H = 520;
var
  scene: TScene; camera: TPerspectiveCamera; renderer: TWebGLRenderer;
  amb: TAmbientLight; sun: TDirectionalLight; floor: TMesh;
  loader: TGLTFLoader; model: TGroup;
  path: string;
  minv, maxv, center: TV3; sf, radius: Single; tris: Integer;

  procedure Bounds(o: TObject3D);
  var k, i: Integer; m: TMesh; p: TV3;
  begin
    if o is TMesh then
    begin
      m:=TMesh(o);
      if m.Geometry<>nil then
        for i:=0 to System.Length(m.Geometry.Pos)-1 do
        begin
          p:=m.Geometry.Pos[i];
          if p.x<minv.x then minv.x:=p.x; if p.y<minv.y then minv.y:=p.y; if p.z<minv.z then minv.z:=p.z;
          if p.x>maxv.x then maxv.x:=p.x; if p.y>maxv.y then maxv.y:=p.y; if p.z>maxv.z then maxv.z:=p.z;
          Inc(tris);
        end;
    end;
    for k:=0 to o.Children.Count-1 do Bounds(TObject3D(o.Children[k]));
  end;

begin
  path:='/Users/andrevanzuydam/IdeaProjects/virtual-office/public/models/sailing-boat.glb';
  if ParamCount>=1 then path:=ParamStr(1);

  loader:=TGLTFLoader.Create;
  model:=loader.Load(path);

  minv:=V3(1e30,1e30,1e30); maxv:=V3(-1e30,-1e30,-1e30); tris:=0;
  Bounds(model);
  if tris=0 then begin WriteLn('no geometry loaded from ', path); Halt(1); end;
  center:=V3((minv.x+maxv.x)/2, (minv.y+maxv.y)/2, (minv.z+maxv.z)/2);
  radius:=maxv.x-minv.x;
  if maxv.y-minv.y>radius then radius:=maxv.y-minv.y;
  if maxv.z-minv.z>radius then radius:=maxv.z-minv.z;
  if radius<1e-6 then radius:=1;
  sf:=4.5/radius;
  WriteLn(Format('loaded %d verts, bounds (%.2f %.2f %.2f)..(%.2f %.2f %.2f), scale %.3f',
    [tris, minv.x,minv.y,minv.z, maxv.x,maxv.y,maxv.z, sf]));

  { centre + scale the loaded model to a sensible size at the origin }
  model.Scale.SetXYZ(sf, sf, sf);
  model.Position.SetXYZ(-sf*center.x, -sf*center.y + 2.2, -sf*center.z);

  scene:=TScene.Create; scene.Background.SetHex($0e0f1f);
  camera:=TPerspectiveCamera.Create(45, W/H, 0.1, 100);
  camera.Position.SetXYZ(6, 4.5, 7); camera.LookAt(0, 1.8, 0);
  renderer:=TWebGLRenderer.Create(W, H);

  amb:=TAmbientLight.Create($ffffff, 0.5); scene.Add(amb);
  sun:=TDirectionalLight.Create($fff4cf, 0.85); sun.Position.SetXYZ(5, 9, 6); scene.Add(sun);
  floor:=TMesh.Create(TPlaneGeometry.Create(40, 40), TMeshStandardMaterial.Create($16172c));
  floor.Rotation.x:=-Pi/2; scene.Add(floor);

  scene.Add(model);
  renderer.Render(scene, camera);
  renderer.SaveBMP('/tmp/t3dgltf.bmp');
  WriteLn('rendered -> /tmp/t3dgltf.bmp');
end.
