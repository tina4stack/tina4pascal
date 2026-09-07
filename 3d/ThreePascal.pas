unit ThreePascal;

{ ThreePascal — a literal Free Pascal port of the three.js subset the Tina4 apps
  use (virtual office, graph-DB views). Same class shapes and method names as
  three.js so JS scene code ports across almost line-for-line.

  RENDERER: pure software — vertices transformed and triangles/lines z-buffered
  and shaded on the CPU straight into an RGBA buffer (which Tina4 composites the
  HTML overlay onto). No OpenGL, no GPU, no window. three.js ships a
  SoftwareRenderer too; a hardware path can slot in later behind this same API.

  v0.2 capabilities:
    math      Vector3, Color, Matrix4, Euler(XYZ)
    graph     Object3D (add/remove/traverse/lookAt), Scene, Group
    cameras   PerspectiveCamera, OrthographicCamera
    geometry  Box, Plane, Sphere, Cylinder, Cone  (+ smooth vertex normals)
    objects   Mesh, Line, LineSegments
    materials MeshBasic/Standard/Lambert/Phong, LineBasicMaterial
    lights    Ambient, Directional, Point
    scene fx  linear Fog (three.Fog)
    shading   per-vertex (Gouraud) diffuse + ambient, z-buffered
  Next: Sprite/text labels, textures, Raycaster, AnimationMixer, GLTFLoader. }

{$mode delphi}{$H+}

interface

uses SysUtils, Classes, Math;

type
  TV3 = record x, y, z: Single; end;
  TMat4 = record m: array[0..15] of Single; end;   // column-major, like three/GL

  TVector3 = class
    x, y, z: Single;
    constructor Create(ax: Single = 0; ay: Single = 0; az: Single = 0);
    function SetXYZ(ax, ay, az: Single): TVector3;
    function Copy(v: TVector3): TVector3;
    function Clone: TVector3;
    function Add(v: TVector3): TVector3;
    function MultiplyScalar(s: Single): TVector3;
    function Length: Single;
    function Normalize: TVector3;
    function V: TV3;
  end;

  TVector2 = class
    x, y: Single;
    constructor Create(ax: Single = 0; ay: Single = 0);
    function SetXY(ax, ay: Single): TVector2;
  end;

  TColor = class
    r, g, b: Single;                                 // 0..1
    constructor Create(hex: LongWord = $ffffff);
    constructor CreateRGB(ar, ag, ab: Single);
    function SetHex(hex: LongWord): TColor;
  end;

  TObject3D = class
    Position, Rotation, Scale: TVector3;             // rotation = Euler XYZ radians
    Children: TList;
    Parent: TObject3D;
    Name: string;
    Visible: Boolean;
    constructor Create;
    destructor Destroy; override;
    function Add(child: TObject3D): TObject3D;
    procedure Remove(child: TObject3D);
    procedure LookAt(tx, ty, tz: Single);            // orient -Z toward target (XYZ euler)
    function WorldMatrix: TMat4;
  end;

  TCamera = class(TObject3D)
    ProjectionMatrix: TMat4;
    ViewMatrix: TMat4;
    procedure UpdateView;                            // from Position + LookAt target
  protected
    FTarget: TV3; FHasTarget: Boolean;
  end;

  TPerspectiveCamera = class(TCamera)
    Fov, Aspect, Near, Far: Single;
    constructor Create(afov, aaspect, anear, afar: Single);
    procedure UpdateProjectionMatrix;
    procedure LookAt(tx, ty, tz: Single);
  end;

  TOrthographicCamera = class(TCamera)
    LeftP, RightP, TopP, BottomP, Near, Far: Single;
    constructor Create(aleft, aright, atop, abottom, anear, afar: Single);
    procedure UpdateProjectionMatrix;
    procedure LookAt(tx, ty, tz: Single);
  end;

  TFog = class
    Color: TColor; Near, Far: Single;
    constructor Create(hex: LongWord; anear, afar: Single);
  end;

  TScene = class(TObject3D)
    Background: TColor;
    Fog: TFog;
    constructor Create;
  end;

  TGroup = class(TObject3D);

  { non-indexed triangle soup: position + (possibly smooth) normal per vertex }
  TBufferGeometry = class
    Pos: array of TV3;
    Normals: array of TV3;
    procedure PushTri(const a, b, c: TV3);                 // flat: one face normal
    procedure PushTriN(const a, b, c, na, nb, nc: TV3);    // smooth: per-vertex normals
  end;

  TBoxGeometry = class(TBufferGeometry)
    constructor Create(w: Single = 1; h: Single = 1; d: Single = 1);
  end;
  TPlaneGeometry = class(TBufferGeometry)                  // in XY plane, +Z normal (three)
    constructor Create(w: Single = 1; h: Single = 1);
  end;
  TSphereGeometry = class(TBufferGeometry)
    constructor Create(radius: Single = 1; widthSeg: Integer = 16; heightSeg: Integer = 12);
  end;
  TCylinderGeometry = class(TBufferGeometry)
    constructor Create(radiusTop: Single = 1; radiusBottom: Single = 1;
                       height: Single = 1; radialSeg: Integer = 16);
  end;
  TConeGeometry = class(TCylinderGeometry)
    constructor Create(radius: Single = 1; height: Single = 1; radialSeg: Integer = 16);
  end;

  { line geometry: a flat list of vertices (LineSegments = pairs; Line = strip) }
  TLineGeometry = class
    Pos: array of TV3;
    procedure Push(x, y, z: Single);
    procedure PushV(const p: TV3);
  end;

  TMaterial = class
    Color: TColor;
    Wireframe: Boolean;
    Opacity: Single;
    constructor Create(acolor: LongWord = $ffffff);
  end;
  TMeshBasicMaterial = class(TMaterial);                   // unlit
  TMeshStandardMaterial = class(TMaterial);                // lit (diffuse)
  TMeshLambertMaterial = class(TMaterial);                 // lit (diffuse)
  TMeshPhongMaterial = class(TMaterial)                    // lit + specular
    Shininess: Single;
    constructor Create(acolor: LongWord = $ffffff);
  end;
  TLineBasicMaterial = class(TMaterial)
    LineWidth: Integer;
    constructor Create(acolor: LongWord = $ffffff);
  end;

  TMesh = class(TObject3D)
    Geometry: TBufferGeometry;
    Material: TMaterial;
    constructor Create(ageometry: TBufferGeometry; amaterial: TMaterial);
  end;

  TLine = class(TObject3D)                                 // connected polyline
    Geometry: TLineGeometry;
    Material: TLineBasicMaterial;
    constructor Create(ageometry: TLineGeometry; amaterial: TLineBasicMaterial);
  end;
  TLineSegments = class(TLine);                            // vertex pairs

  TLight = class(TObject3D)
    Color: TColor;
    Intensity: Single;
  end;
  TAmbientLight = class(TLight)
    constructor Create(acolor: LongWord = $ffffff; aintensity: Single = 1);
  end;
  TDirectionalLight = class(TLight)
    constructor Create(acolor: LongWord = $ffffff; aintensity: Single = 1);
  end;
  TPointLight = class(TLight)
    Distance: Single;                                      // 0 = no attenuation range
    constructor Create(acolor: LongWord = $ffffff; aintensity: Single = 1; adistance: Single = 0);
  end;

  { ---- picking (three.Raycaster) ---- }
  TRay = record origin, direction: TV3; end;
  TIntersection = record
    Hit: Boolean; Distance: Single; Point: TV3; Obj: TObject3D;
  end;

  TRaycaster = class
    Ray: TRay; Near, Far: Single;
    constructor Create;
    procedure SetRay(const origin, direction: TV3);
    procedure SetFromCamera(ndcX, ndcY: Single; camera: TCamera);  // NDC coords in [-1,1]
    function IntersectObject(root: TObject3D; recursive: Boolean = True): TIntersection;
  end;

  TWebGLRenderer = class
  private
    FW, FH: Integer;
    FZ: array of Single;
    procedure PlotDepth(px, py: Integer; z, r, g, b: Single);
    procedure RasterTri(const a, b, c, ca, cb, cc: TV3);   // screen x/y/ndc-z + per-vertex RGB
    procedure RasterLine(const a, b: TV3; r, g, b2: Single; w: Integer);
  public
    Pixels: array of Byte;                                 // RGBA, FW*FH*4
    constructor Create(width, height: Integer);
    procedure SetSize(width, height: Integer);
    procedure Render(scene: TScene; camera: TCamera);
    procedure SaveBMP(const fn: string);
    property Width: Integer read FW;
    property Height: Integer read FH;
  end;

function V3(x, y, z: Single): TV3;
function Mat4Identity: TMat4;
function Mat4Multiply(const a, b: TMat4): TMat4;
function Mat4Perspective(fovYdeg, aspect, near, far: Single): TMat4;
function Mat4Ortho(l, r, t, b, n, f: Single): TMat4;
function Mat4LookAt(const eye, center, up: TV3): TMat4;
function Mat4Compose(const pos, rotEuler, scl: TV3): TMat4;
function Mat4TransformPoint(const mat: TMat4; const p: TV3): TV3;
function Mat4TransformDir(const mat: TMat4; const d: TV3): TV3;
function Mat4Invert(const a: TMat4): TMat4;

implementation

{ ============================ value math ============================ }

function V3(x, y, z: Single): TV3; begin Result.x:=x; Result.y:=y; Result.z:=z; end;
function VSub(const a, b: TV3): TV3; begin Result:=V3(a.x-b.x,a.y-b.y,a.z-b.z); end;
function VAdd(const a, b: TV3): TV3; begin Result:=V3(a.x+b.x,a.y+b.y,a.z+b.z); end;
function VScale(const a: TV3; s: Single): TV3; begin Result:=V3(a.x*s,a.y*s,a.z*s); end;
function VCross(const a, b: TV3): TV3;
begin Result:=V3(a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x); end;
function VDot(const a, b: TV3): Single; begin Result:=a.x*b.x+a.y*b.y+a.z*b.z; end;
function VLen(const a: TV3): Single; begin Result:=Sqrt(a.x*a.x+a.y*a.y+a.z*a.z); end;
function VNorm(const a: TV3): TV3;
var l: Single; begin l:=VLen(a); if l<1e-9 then l:=1; Result:=V3(a.x/l,a.y/l,a.z/l); end;

function Mat4Identity: TMat4;
var i: Integer; begin for i:=0 to 15 do Result.m[i]:=0;
  Result.m[0]:=1; Result.m[5]:=1; Result.m[10]:=1; Result.m[15]:=1; end;

function Mat4Multiply(const a, b: TMat4): TMat4;
var c, r, k: Integer; s: Single;
begin
  for c:=0 to 3 do for r:=0 to 3 do
  begin s:=0; for k:=0 to 3 do s:=s+a.m[k*4+r]*b.m[c*4+k]; Result.m[c*4+r]:=s; end;
end;

function Mat4Perspective(fovYdeg, aspect, near, far: Single): TMat4;
var f: Single;
begin
  Result:=Mat4Identity; f:=1/Tan((fovYdeg*Pi/180)/2);
  Result.m[0]:=f/aspect; Result.m[5]:=f;
  Result.m[10]:=(far+near)/(near-far); Result.m[11]:=-1;
  Result.m[14]:=(2*far*near)/(near-far); Result.m[15]:=0;
end;

function Mat4Ortho(l, r, t, b, n, f: Single): TMat4;
begin
  Result:=Mat4Identity;
  Result.m[0]:=2/(r-l); Result.m[5]:=2/(t-b); Result.m[10]:=-2/(f-n);
  Result.m[12]:=-(r+l)/(r-l); Result.m[13]:=-(t+b)/(t-b); Result.m[14]:=-(f+n)/(f-n);
end;

function Mat4LookAt(const eye, center, up: TV3): TMat4;
var f, s, u: TV3;
begin
  f:=VNorm(VSub(center, eye)); s:=VNorm(VCross(f, up)); u:=VCross(s, f);
  Result:=Mat4Identity;
  Result.m[0]:=s.x; Result.m[4]:=s.y; Result.m[8]:=s.z;
  Result.m[1]:=u.x; Result.m[5]:=u.y; Result.m[9]:=u.z;
  Result.m[2]:=-f.x; Result.m[6]:=-f.y; Result.m[10]:=-f.z;
  Result.m[12]:=-VDot(s, eye); Result.m[13]:=-VDot(u, eye); Result.m[14]:=VDot(f, eye);
end;

function Mat4Translate(x, y, z: Single): TMat4;
begin Result:=Mat4Identity; Result.m[12]:=x; Result.m[13]:=y; Result.m[14]:=z; end;
function Mat4Scale(x, y, z: Single): TMat4;
begin Result:=Mat4Identity; Result.m[0]:=x; Result.m[5]:=y; Result.m[10]:=z; end;
function Mat4RotX(a: Single): TMat4;
var c, s: Single; begin c:=Cos(a); s:=Sin(a); Result:=Mat4Identity;
  Result.m[5]:=c; Result.m[6]:=s; Result.m[9]:=-s; Result.m[10]:=c; end;
function Mat4RotY(a: Single): TMat4;
var c, s: Single; begin c:=Cos(a); s:=Sin(a); Result:=Mat4Identity;
  Result.m[0]:=c; Result.m[2]:=-s; Result.m[8]:=s; Result.m[10]:=c; end;
function Mat4RotZ(a: Single): TMat4;
var c, s: Single; begin c:=Cos(a); s:=Sin(a); Result:=Mat4Identity;
  Result.m[0]:=c; Result.m[1]:=s; Result.m[4]:=-s; Result.m[5]:=c; end;

function Mat4Compose(const pos, rotEuler, scl: TV3): TMat4;
var r: TMat4;
begin
  r:=Mat4Multiply(Mat4RotX(rotEuler.x), Mat4Multiply(Mat4RotY(rotEuler.y), Mat4RotZ(rotEuler.z)));
  Result:=Mat4Multiply(Mat4Translate(pos.x,pos.y,pos.z),
          Mat4Multiply(r, Mat4Scale(scl.x,scl.y,scl.z)));
end;

function Mat4TransformPoint(const mat: TMat4; const p: TV3): TV3;
var x, y, z, w: Single;
begin
  x:=mat.m[0]*p.x+mat.m[4]*p.y+mat.m[8]*p.z+mat.m[12];
  y:=mat.m[1]*p.x+mat.m[5]*p.y+mat.m[9]*p.z+mat.m[13];
  z:=mat.m[2]*p.x+mat.m[6]*p.y+mat.m[10]*p.z+mat.m[14];
  w:=mat.m[3]*p.x+mat.m[7]*p.y+mat.m[11]*p.z+mat.m[15];
  if Abs(w)<1e-9 then w:=1e-9;
  Result:=V3(x/w, y/w, z/w);
end;

function Mat4TransformDir(const mat: TMat4; const d: TV3): TV3;
begin
  Result:=V3(mat.m[0]*d.x+mat.m[4]*d.y+mat.m[8]*d.z,
             mat.m[1]*d.x+mat.m[5]*d.y+mat.m[9]*d.z,
             mat.m[2]*d.x+mat.m[6]*d.y+mat.m[10]*d.z);
end;

{ general 4x4 inverse (cofactor method) — for unprojecting screen coords to rays }
function Mat4Invert(const a: TMat4): TMat4;
var inv: array[0..15] of Single; det: Single; i: Integer; m: array[0..15] of Single;
begin
  for i:=0 to 15 do m[i]:=a.m[i];
  inv[0]:= m[5]*m[10]*m[15]-m[5]*m[11]*m[14]-m[9]*m[6]*m[15]+m[9]*m[7]*m[14]+m[13]*m[6]*m[11]-m[13]*m[7]*m[10];
  inv[4]:=-m[4]*m[10]*m[15]+m[4]*m[11]*m[14]+m[8]*m[6]*m[15]-m[8]*m[7]*m[14]-m[12]*m[6]*m[11]+m[12]*m[7]*m[10];
  inv[8]:= m[4]*m[9]*m[15]-m[4]*m[11]*m[13]-m[8]*m[5]*m[15]+m[8]*m[7]*m[13]+m[12]*m[5]*m[11]-m[12]*m[7]*m[9];
  inv[12]:=-m[4]*m[9]*m[14]+m[4]*m[10]*m[13]+m[8]*m[5]*m[14]-m[8]*m[6]*m[13]-m[12]*m[5]*m[10]+m[12]*m[6]*m[9];
  inv[1]:=-m[1]*m[10]*m[15]+m[1]*m[11]*m[14]+m[9]*m[2]*m[15]-m[9]*m[3]*m[14]-m[13]*m[2]*m[11]+m[13]*m[3]*m[10];
  inv[5]:= m[0]*m[10]*m[15]-m[0]*m[11]*m[14]-m[8]*m[2]*m[15]+m[8]*m[3]*m[14]+m[12]*m[2]*m[11]-m[12]*m[3]*m[10];
  inv[9]:=-m[0]*m[9]*m[15]+m[0]*m[11]*m[13]+m[8]*m[1]*m[15]-m[8]*m[3]*m[13]-m[12]*m[1]*m[11]+m[12]*m[3]*m[9];
  inv[13]:= m[0]*m[9]*m[14]-m[0]*m[10]*m[13]-m[8]*m[1]*m[14]+m[8]*m[2]*m[13]+m[12]*m[1]*m[10]-m[12]*m[2]*m[9];
  inv[2]:= m[1]*m[6]*m[15]-m[1]*m[7]*m[14]-m[5]*m[2]*m[15]+m[5]*m[3]*m[14]+m[13]*m[2]*m[7]-m[13]*m[3]*m[6];
  inv[6]:=-m[0]*m[6]*m[15]+m[0]*m[7]*m[14]+m[4]*m[2]*m[15]-m[4]*m[3]*m[14]-m[12]*m[2]*m[7]+m[12]*m[3]*m[6];
  inv[10]:= m[0]*m[5]*m[15]-m[0]*m[7]*m[13]-m[4]*m[1]*m[15]+m[4]*m[3]*m[13]+m[12]*m[1]*m[7]-m[12]*m[3]*m[5];
  inv[14]:=-m[0]*m[5]*m[14]+m[0]*m[6]*m[13]+m[4]*m[1]*m[14]-m[4]*m[2]*m[13]-m[12]*m[1]*m[6]+m[12]*m[2]*m[5];
  inv[3]:=-m[1]*m[6]*m[11]+m[1]*m[7]*m[10]+m[5]*m[2]*m[11]-m[5]*m[3]*m[10]-m[9]*m[2]*m[7]+m[9]*m[3]*m[6];
  inv[7]:= m[0]*m[6]*m[11]-m[0]*m[7]*m[10]-m[4]*m[2]*m[11]+m[4]*m[3]*m[10]+m[8]*m[2]*m[7]-m[8]*m[3]*m[6];
  inv[11]:=-m[0]*m[5]*m[11]+m[0]*m[7]*m[9]+m[4]*m[1]*m[11]-m[4]*m[3]*m[9]-m[8]*m[1]*m[7]+m[8]*m[3]*m[5];
  inv[15]:= m[0]*m[5]*m[10]-m[0]*m[6]*m[9]-m[4]*m[1]*m[10]+m[4]*m[2]*m[9]+m[8]*m[1]*m[6]-m[8]*m[2]*m[5];
  det:=m[0]*inv[0]+m[1]*inv[4]+m[2]*inv[8]+m[3]*inv[12];
  if Abs(det)<1e-12 then begin Result:=Mat4Identity; Exit; end;
  det:=1/det;
  for i:=0 to 15 do Result.m[i]:=inv[i]*det;
end;

{ Möller–Trumbore: ray o+t·d vs triangle; returns t>eps on hit }
function RayTri(const o, d, v0, v1, v2: TV3; out t: Single): Boolean;
var e1, e2, p, q, tv: TV3; det, invDet, u, vp: Single;
begin
  Result:=False; t:=0;
  e1:=VSub(v1,v0); e2:=VSub(v2,v0); p:=VCross(d,e2); det:=VDot(e1,p);
  if Abs(det)<1e-8 then Exit;                         // parallel
  invDet:=1/det; tv:=VSub(o,v0); u:=VDot(tv,p)*invDet;
  if (u<0) or (u>1) then Exit;
  q:=VCross(tv,e1); vp:=VDot(d,q)*invDet;
  if (vp<0) or (u+vp>1) then Exit;
  t:=VDot(e2,q)*invDet;
  Result:=t>1e-5;
end;

{ ============================ TVector3 / TColor ============================ }

constructor TVector3.Create(ax, ay, az: Single); begin x:=ax; y:=ay; z:=az; end;
function TVector3.SetXYZ(ax, ay, az: Single): TVector3; begin x:=ax; y:=ay; z:=az; Result:=Self; end;
function TVector3.Copy(v: TVector3): TVector3; begin x:=v.x; y:=v.y; z:=v.z; Result:=Self; end;
function TVector3.Clone: TVector3; begin Result:=TVector3.Create(x,y,z); end;
function TVector3.Add(v: TVector3): TVector3; begin x:=x+v.x; y:=y+v.y; z:=z+v.z; Result:=Self; end;
function TVector3.MultiplyScalar(s: Single): TVector3; begin x:=x*s; y:=y*s; z:=z*s; Result:=Self; end;
function TVector3.Length: Single; begin Result:=Sqrt(x*x+y*y+z*z); end;
function TVector3.Normalize: TVector3;
var l: Single; begin l:=Length; if l<1e-9 then l:=1; x:=x/l; y:=y/l; z:=z/l; Result:=Self; end;
function TVector3.V: TV3; begin Result:=V3(x,y,z); end;

constructor TVector2.Create(ax, ay: Single); begin x:=ax; y:=ay; end;
function TVector2.SetXY(ax, ay: Single): TVector2; begin x:=ax; y:=ay; Result:=Self; end;

constructor TColor.Create(hex: LongWord); begin SetHex(hex); end;
constructor TColor.CreateRGB(ar, ag, ab: Single); begin r:=ar; g:=ag; b:=ab; end;
function TColor.SetHex(hex: LongWord): TColor;
begin r:=((hex shr 16) and $ff)/255; g:=((hex shr 8) and $ff)/255; b:=(hex and $ff)/255; Result:=Self; end;

{ ============================ TObject3D ============================ }

constructor TObject3D.Create;
begin
  Position:=TVector3.Create(0,0,0); Rotation:=TVector3.Create(0,0,0); Scale:=TVector3.Create(1,1,1);
  Children:=TList.Create; Parent:=nil; Visible:=True; Name:='';
end;

destructor TObject3D.Destroy;
var i: Integer;
begin
  for i:=0 to Children.Count-1 do TObject(Children[i]).Free;
  Children.Free; Position.Free; Rotation.Free; Scale.Free; inherited;
end;

function TObject3D.Add(child: TObject3D): TObject3D;
begin child.Parent:=Self; Children.Add(child); Result:=Self; end;

procedure TObject3D.Remove(child: TObject3D);
var i: Integer;
begin i:=Children.IndexOf(child); if i>=0 then begin Children.Delete(i); child.Parent:=nil; end; end;

procedure TObject3D.LookAt(tx, ty, tz: Single);
var f: TV3;
begin
  { orient so the object's forward (-Z) points at the target. Yaw+pitch (roll 0),
    which covers billboards, cameras-as-objects and the office's facing needs. }
  f:=VNorm(VSub(V3(tx,ty,tz), Position.V));
  Rotation.y:=ArcTan2(f.x, f.z);
  Rotation.x:=ArcTan2(-f.y, Sqrt(f.x*f.x + f.z*f.z));
  Rotation.z:=0;
end;

function TObject3D.WorldMatrix: TMat4;
var local: TMat4;
begin
  local:=Mat4Compose(Position.V, Rotation.V, Scale.V);
  if Parent<>nil then Result:=Mat4Multiply(Parent.WorldMatrix, local) else Result:=local;
end;

{ ============================ cameras ============================ }

procedure TCamera.UpdateView;
begin
  if FHasTarget then ViewMatrix:=Mat4LookAt(Position.V, FTarget, V3(0,1,0))
  else ViewMatrix:=Mat4LookAt(Position.V, VAdd(Position.V, V3(0,0,-1)), V3(0,1,0));
end;

constructor TPerspectiveCamera.Create(afov, aaspect, anear, afar: Single);
begin
  inherited Create; Fov:=afov; Aspect:=aaspect; Near:=anear; Far:=afar;
  FHasTarget:=False; ViewMatrix:=Mat4Identity; UpdateProjectionMatrix; UpdateView;
end;
procedure TPerspectiveCamera.UpdateProjectionMatrix;
begin ProjectionMatrix:=Mat4Perspective(Fov, Aspect, Near, Far); end;
procedure TPerspectiveCamera.LookAt(tx, ty, tz: Single);
begin FTarget:=V3(tx,ty,tz); FHasTarget:=True; UpdateView; end;

constructor TOrthographicCamera.Create(aleft, aright, atop, abottom, anear, afar: Single);
begin
  inherited Create; LeftP:=aleft; RightP:=aright; TopP:=atop; BottomP:=abottom;
  Near:=anear; Far:=afar; FHasTarget:=False; ViewMatrix:=Mat4Identity;
  UpdateProjectionMatrix; UpdateView;
end;
procedure TOrthographicCamera.UpdateProjectionMatrix;
begin ProjectionMatrix:=Mat4Ortho(LeftP, RightP, TopP, BottomP, Near, Far); end;
procedure TOrthographicCamera.LookAt(tx, ty, tz: Single);
begin FTarget:=V3(tx,ty,tz); FHasTarget:=True; UpdateView; end;

constructor TFog.Create(hex: LongWord; anear, afar: Single);
begin Color:=TColor.Create(hex); Near:=anear; Far:=afar; end;

constructor TScene.Create;
begin inherited Create; Background:=TColor.Create($000000); Fog:=nil; end;

{ ============================ geometry ============================ }

procedure TBufferGeometry.PushTri(const a, b, c: TV3);
var n: TV3; i: Integer;
begin
  n:=VNorm(VCross(VSub(b,a), VSub(c,a)));
  i:=System.Length(Pos); SetLength(Pos,i+3); SetLength(Normals,i+3);
  Pos[i]:=a; Pos[i+1]:=b; Pos[i+2]:=c;
  Normals[i]:=n; Normals[i+1]:=n; Normals[i+2]:=n;
end;

procedure TBufferGeometry.PushTriN(const a, b, c, na, nb, nc: TV3);
var i: Integer;
begin
  i:=System.Length(Pos); SetLength(Pos,i+3); SetLength(Normals,i+3);
  Pos[i]:=a; Pos[i+1]:=b; Pos[i+2]:=c;
  Normals[i]:=na; Normals[i+1]:=nb; Normals[i+2]:=nc;
end;

constructor TBoxGeometry.Create(w, h, d: Single);
var hx, hy, hz: Single;
  procedure Quad(const a,b,c,dd: TV3); begin PushTri(a,b,c); PushTri(a,c,dd); end;
begin
  inherited Create; hx:=w/2; hy:=h/2; hz:=d/2;
  Quad(V3(-hx,-hy,hz),V3(hx,-hy,hz),V3(hx,hy,hz),V3(-hx,hy,hz));
  Quad(V3(hx,-hy,-hz),V3(-hx,-hy,-hz),V3(-hx,hy,-hz),V3(hx,hy,-hz));
  Quad(V3(hx,-hy,hz),V3(hx,-hy,-hz),V3(hx,hy,-hz),V3(hx,hy,hz));
  Quad(V3(-hx,-hy,-hz),V3(-hx,-hy,hz),V3(-hx,hy,hz),V3(-hx,hy,-hz));
  Quad(V3(-hx,hy,hz),V3(hx,hy,hz),V3(hx,hy,-hz),V3(-hx,hy,-hz));
  Quad(V3(-hx,-hy,-hz),V3(hx,-hy,-hz),V3(hx,-hy,hz),V3(-hx,-hy,hz));
end;

constructor TPlaneGeometry.Create(w, h: Single);
var hx, hy: Single;
begin
  inherited Create; hx:=w/2; hy:=h/2;
  PushTri(V3(-hx,-hy,0),V3(hx,-hy,0),V3(hx,hy,0));
  PushTri(V3(-hx,-hy,0),V3(hx,hy,0),V3(-hx,hy,0));
end;

constructor TSphereGeometry.Create(radius: Single; widthSeg, heightSeg: Integer);
var iy, ix: Integer; u, vv, theta, phi: Single; p: array of array of TV3;
  function SP(t, ph: Single): TV3;
  begin Result:=V3(radius*Sin(ph)*Cos(t), radius*Cos(ph), radius*Sin(ph)*Sin(t)); end;
begin
  inherited Create;
  SetLength(p, heightSeg+1, widthSeg+1);
  for iy:=0 to heightSeg do
  begin vv:=iy/heightSeg; phi:=vv*Pi;
    for ix:=0 to widthSeg do
    begin u:=ix/widthSeg; theta:=u*2*Pi; p[iy][ix]:=SP(theta, phi); end;
  end;
  for iy:=0 to heightSeg-1 do
    for ix:=0 to widthSeg-1 do
    begin
      { two tris per quad; vertex normal = normalize(position) for a unit sphere }
      PushTriN(p[iy][ix], p[iy+1][ix], p[iy+1][ix+1],
               VNorm(p[iy][ix]), VNorm(p[iy+1][ix]), VNorm(p[iy+1][ix+1]));
      PushTriN(p[iy][ix], p[iy+1][ix+1], p[iy][ix+1],
               VNorm(p[iy][ix]), VNorm(p[iy+1][ix+1]), VNorm(p[iy][ix+1]));
    end;
end;

constructor TCylinderGeometry.Create(radiusTop, radiusBottom, height: Single; radialSeg: Integer);
var i: Integer; a0, a1, hy: Single; t0, t1, b0, b1, nt0, nt1: TV3; cT, cB: TV3;
begin
  inherited Create; hy:=height/2; cT:=V3(0,hy,0); cB:=V3(0,-hy,0);
  for i:=0 to radialSeg-1 do
  begin
    a0:=(i/radialSeg)*2*Pi; a1:=((i+1)/radialSeg)*2*Pi;
    t0:=V3(radiusTop*Cos(a0),hy,radiusTop*Sin(a0));
    t1:=V3(radiusTop*Cos(a1),hy,radiusTop*Sin(a1));
    b0:=V3(radiusBottom*Cos(a0),-hy,radiusBottom*Sin(a0));
    b1:=V3(radiusBottom*Cos(a1),-hy,radiusBottom*Sin(a1));
    nt0:=VNorm(V3(Cos(a0),0,Sin(a0))); nt1:=VNorm(V3(Cos(a1),0,Sin(a1)));
    { side (skip degenerate edge when a radius is 0, e.g. cone tip) }
    if radiusTop>1e-6 then PushTriN(t0,b0,b1, nt0,nt0,nt1);
    if radiusBottom>1e-6 then PushTriN(t0,b1,t1, nt0,nt1,nt1);
    if (radiusTop<=1e-6) then PushTriN(t0,b0,b1, VNorm(VAdd(nt0,nt1)),nt0,nt1);
    { caps (flat) }
    if radiusTop>1e-6 then PushTri(cT, t1, t0);
    if radiusBottom>1e-6 then PushTri(cB, b0, b1);
  end;
end;

constructor TConeGeometry.Create(radius, height: Single; radialSeg: Integer);
begin inherited Create(0, radius, height, radialSeg); end;

procedure TLineGeometry.Push(x, y, z: Single);
var i: Integer; begin i:=System.Length(Pos); SetLength(Pos,i+1); Pos[i]:=V3(x,y,z); end;
procedure TLineGeometry.PushV(const p: TV3);
var i: Integer; begin i:=System.Length(Pos); SetLength(Pos,i+1); Pos[i]:=p; end;

{ ============================ materials / objects / lights ============================ }

constructor TMaterial.Create(acolor: LongWord);
begin Color:=TColor.Create(acolor); Wireframe:=False; Opacity:=1; end;
constructor TMeshPhongMaterial.Create(acolor: LongWord);
begin inherited Create(acolor); Shininess:=30; end;
constructor TLineBasicMaterial.Create(acolor: LongWord);
begin inherited Create(acolor); LineWidth:=1; end;

constructor TMesh.Create(ageometry: TBufferGeometry; amaterial: TMaterial);
begin inherited Create; Geometry:=ageometry; Material:=amaterial; end;
constructor TLine.Create(ageometry: TLineGeometry; amaterial: TLineBasicMaterial);
begin inherited Create; Geometry:=ageometry; Material:=amaterial; end;

constructor TAmbientLight.Create(acolor: LongWord; aintensity: Single);
begin inherited Create; Color:=TColor.Create(acolor); Intensity:=aintensity; end;
constructor TDirectionalLight.Create(acolor: LongWord; aintensity: Single);
begin inherited Create; Color:=TColor.Create(acolor); Intensity:=aintensity; Position.SetXYZ(1,1,1); end;
constructor TPointLight.Create(acolor: LongWord; aintensity: Single; adistance: Single);
begin inherited Create; Color:=TColor.Create(acolor); Intensity:=aintensity; Distance:=adistance; end;

{ ============================ raycaster (picking) ============================ }

constructor TRaycaster.Create;
begin Near:=0; Far:=1e30; Ray.origin:=V3(0,0,0); Ray.direction:=V3(0,0,-1); end;

procedure TRaycaster.SetRay(const origin, direction: TV3);
begin Ray.origin:=origin; Ray.direction:=VNorm(direction); end;

procedure TRaycaster.SetFromCamera(ndcX, ndcY: Single; camera: TCamera);
var vp, inv: TMat4; pNear, pFar: TV3;
begin
  vp:=Mat4Multiply(camera.ProjectionMatrix, camera.ViewMatrix);
  inv:=Mat4Invert(vp);
  pNear:=Mat4TransformPoint(inv, V3(ndcX, ndcY, -1));   // near plane
  pFar :=Mat4TransformPoint(inv, V3(ndcX, ndcY,  1));   // far plane
  Ray.origin:=camera.Position.V;
  Ray.direction:=VNorm(VSub(pFar, pNear));
end;

function TRaycaster.IntersectObject(root: TObject3D; recursive: Boolean): TIntersection;
var best: TIntersection;

  procedure Test(o: TObject3D);
  var k, tri: Integer; mesh: TMesh; g: TBufferGeometry; wm: TMat4;
      a, b, c: TV3; t: Single;
  begin
    if not o.Visible then Exit;
    if o is TMesh then
    begin
      mesh:=TMesh(o); g:=mesh.Geometry;
      if g<>nil then
      begin
        wm:=o.WorldMatrix; tri:=0;
        while tri+2<System.Length(g.Pos) do
        begin
          a:=Mat4TransformPoint(wm, g.Pos[tri]);
          b:=Mat4TransformPoint(wm, g.Pos[tri+1]);
          c:=Mat4TransformPoint(wm, g.Pos[tri+2]);
          if RayTri(Ray.origin, Ray.direction, a, b, c, t) then
            if (t>=Near) and (t<=Far) and (t<best.Distance) then
            begin
              best.Hit:=True; best.Distance:=t;
              best.Point:=VAdd(Ray.origin, VScale(Ray.direction, t)); best.Obj:=o;
            end;
          tri:=tri+3;
        end;
      end;
    end;
    if recursive then
      for k:=0 to o.Children.Count-1 do Test(TObject3D(o.Children[k]));
  end;

begin
  best.Hit:=False; best.Distance:=1e30; best.Obj:=nil; best.Point:=V3(0,0,0);
  Test(root);
  Result:=best;
end;

{ ============================ software renderer ============================ }

constructor TWebGLRenderer.Create(width, height: Integer);
begin SetSize(width, height); end;
procedure TWebGLRenderer.SetSize(width, height: Integer);
begin FW:=width; FH:=height; SetLength(Pixels,FW*FH*4); SetLength(FZ,FW*FH); end;

function ClampB(v: Single): Byte;
begin if v<0 then v:=0; if v>1 then v:=1; Result:=Round(v*255); end;

procedure TWebGLRenderer.PlotDepth(px, py: Integer; z, r, g, b: Single);
var idx: Integer;
begin
  if (px<0) or (py<0) or (px>=FW) or (py>=FH) then Exit;
  idx:=py*FW+px;
  if z<FZ[idx] then
  begin FZ[idx]:=z;
    Pixels[idx*4+0]:=ClampB(r); Pixels[idx*4+1]:=ClampB(g);
    Pixels[idx*4+2]:=ClampB(b); Pixels[idx*4+3]:=255;
  end;
end;

{ Gouraud triangle: a/b/c carry screen x,y and ndc z; ca/cb/cc are per-vertex RGB }
procedure TWebGLRenderer.RasterTri(const a, b, c, ca, cb, cc: TV3);
var minx, maxx, miny, maxy, px, py, idx: Integer; area, w0, w1, w2, z, iw: Single;
  function Edge(const p0, p1: TV3; x, y: Single): Single;
  begin Result:=(x-p0.x)*(p1.y-p0.y)-(y-p0.y)*(p1.x-p0.x); end;
begin
  area:=Edge(a,b,c.x,c.y); if Abs(area)<1e-6 then Exit;
  minx:=Trunc(Min(a.x,Min(b.x,c.x))); maxx:=Trunc(Max(a.x,Max(b.x,c.x)))+1;
  miny:=Trunc(Min(a.y,Min(b.y,c.y))); maxy:=Trunc(Max(a.y,Max(b.y,c.y)))+1;
  if minx<0 then minx:=0; if miny<0 then miny:=0;
  if maxx>FW then maxx:=FW; if maxy>FH then maxy:=FH;
  for py:=miny to maxy-1 do
    for px:=minx to maxx-1 do
    begin
      w0:=Edge(b,c,px+0.5,py+0.5); w1:=Edge(c,a,px+0.5,py+0.5); w2:=Edge(a,b,px+0.5,py+0.5);
      if ((w0>=0)and(w1>=0)and(w2>=0)) or ((w0<=0)and(w1<=0)and(w2<=0)) then
      begin
        w0:=w0/area; w1:=w1/area; w2:=w2/area;
        z:=w0*a.z+w1*b.z+w2*c.z;
        idx:=py*FW+px;
        if z<FZ[idx] then
        begin FZ[idx]:=z; iw:=1;
          Pixels[idx*4+0]:=ClampB(w0*ca.x+w1*cb.x+w2*cc.x);
          Pixels[idx*4+1]:=ClampB(w0*ca.y+w1*cb.y+w2*cc.y);
          Pixels[idx*4+2]:=ClampB(w0*ca.z+w1*cb.z+w2*cc.z);
          Pixels[idx*4+3]:=255;
        end;
      end;
    end;
end;

procedure TWebGLRenderer.RasterLine(const a, b: TV3; r, g, b2: Single; w: Integer);
var dx, dy, steps, i, ox, oy: Integer; x, y, z, sx, sy, sz: Single;
begin
  dx:=Trunc(Abs(b.x-a.x)); dy:=Trunc(Abs(b.y-a.y));
  steps:=dx; if dy>steps then steps:=dy; if steps<1 then steps:=1;
  sx:=(b.x-a.x)/steps; sy:=(b.y-a.y)/steps; sz:=(b.z-a.z)/steps;
  x:=a.x; y:=a.y; z:=a.z;
  for i:=0 to steps do
  begin
    for ox:=0 to w-1 do for oy:=0 to w-1 do
      PlotDepth(Trunc(x)+ox, Trunc(y)+oy, z-1e-4, r, g, b2);   // slight bias so lines sit atop faces
    x:=x+sx; y:=y+sy; z:=z+sz;
  end;
end;

procedure TWebGLRenderer.Render(scene: TScene; camera: TCamera);
var
  i: Integer; vp: TMat4; ambient: TV3;
  dirs, dcols: array of TV3;                 // directional: world dir + colour*intensity
  plpos, plcol: array of TV3; plrange: array of Single;  // point lights
  bg: TColor; camPos: TV3;

  function Fogged(const col: TV3; const worldPos: TV3): TV3;
  var d, f: Single;
  begin
    Result:=col;
    if scene.Fog<>nil then
    begin
      d:=VLen(VSub(worldPos, camPos));
      f:=(scene.Fog.Far-d)/(scene.Fog.Far-scene.Fog.Near);
      if f<0 then f:=0; if f>1 then f:=1;
      Result:=V3(scene.Fog.Color.r*(1-f)+col.x*f,
                 scene.Fog.Color.g*(1-f)+col.y*f,
                 scene.Fog.Color.b*(1-f)+col.z*f);
    end;
  end;

  function ShadeVertex(const wp, wn: TV3; base: TColor; unlit: Boolean): TV3;
  var li: Integer; ndl, d, att: Single; col, L: TV3;
  begin
    if unlit then begin Result:=Fogged(V3(base.r,base.g,base.b), wp); Exit; end;
    col:=V3(base.r*ambient.x, base.g*ambient.y, base.b*ambient.z);
    for li:=0 to System.Length(dirs)-1 do
    begin
      ndl:=VDot(wn, dirs[li]); if ndl<0 then ndl:=0;
      col:=V3(col.x+base.r*dcols[li].x*ndl, col.y+base.g*dcols[li].y*ndl, col.z+base.b*dcols[li].z*ndl);
    end;
    for li:=0 to System.Length(plpos)-1 do
    begin
      L:=VSub(plpos[li], wp); d:=VLen(L); if d<1e-4 then d:=1e-4; L:=VScale(L,1/d);
      ndl:=VDot(wn, L); if ndl<0 then ndl:=0;
      att:=1; if plrange[li]>0 then begin att:=1-(d/plrange[li]); if att<0 then att:=0; end;
      col:=V3(col.x+base.r*plcol[li].x*ndl*att, col.y+base.g*plcol[li].y*ndl*att, col.z+base.b*plcol[li].z*ndl*att);
    end;
    Result:=Fogged(col, wp);
  end;

  procedure CollectLights(o: TObject3D);
  var k: Integer; dl: TDirectionalLight; al: TAmbientLight; pl: TPointLight; wm: TMat4;
  begin
    if o is TAmbientLight then
    begin al:=TAmbientLight(o);
      ambient:=V3(ambient.x+al.Color.r*al.Intensity, ambient.y+al.Color.g*al.Intensity, ambient.z+al.Color.b*al.Intensity);
    end
    else if o is TDirectionalLight then
    begin dl:=TDirectionalLight(o); k:=System.Length(dirs); SetLength(dirs,k+1); SetLength(dcols,k+1);
      dirs[k]:=VNorm(dl.Position.V);
      dcols[k]:=V3(dl.Color.r*dl.Intensity, dl.Color.g*dl.Intensity, dl.Color.b*dl.Intensity);
    end
    else if o is TPointLight then
    begin pl:=TPointLight(o); wm:=o.WorldMatrix; k:=System.Length(plpos);
      SetLength(plpos,k+1); SetLength(plcol,k+1); SetLength(plrange,k+1);
      plpos[k]:=V3(wm.m[12],wm.m[13],wm.m[14]);
      plcol[k]:=V3(pl.Color.r*pl.Intensity, pl.Color.g*pl.Intensity, pl.Color.b*pl.Intensity);
      plrange[k]:=pl.Distance;
    end;
    for k:=0 to o.Children.Count-1 do CollectLights(TObject3D(o.Children[k]));
  end;

  procedure RenderObject(o: TObject3D);
  var k, tri: Integer; mesh: TMesh; ln: TLine; g: TBufferGeometry; lg: TLineGeometry;
      worldM, mvp: TMat4; base: TColor; unlit: Boolean;
      wp: array[0..2] of TV3; wn: array[0..2] of TV3; sp: array[0..2] of TV3; col: array[0..2] of TV3;
      lc: TV3; a, bb: TV3;
    function ToScreen(const clip: TV3): TV3;
    begin Result:=V3((clip.x*0.5+0.5)*FW, (1-(clip.y*0.5+0.5))*FH, clip.z); end;
  begin
    if not o.Visible then Exit;
    worldM:=o.WorldMatrix; mvp:=Mat4Multiply(vp, worldM);
    if o is TMesh then
    begin
      mesh:=TMesh(o); g:=mesh.Geometry;
      if (g<>nil) and (mesh.Material<>nil) then
      begin
        base:=mesh.Material.Color; unlit:=mesh.Material is TMeshBasicMaterial;
        tri:=0;
        while tri+2<System.Length(g.Pos) do
        begin
          for k:=0 to 2 do
          begin
            wp[k]:=Mat4TransformPoint(worldM, g.Pos[tri+k]);
            wn[k]:=VNorm(Mat4TransformDir(worldM, g.Normals[tri+k]));
            col[k]:=ShadeVertex(wp[k], wn[k], base, unlit);
            sp[k]:=ToScreen(Mat4TransformPoint(mvp, g.Pos[tri+k]));
          end;
          RasterTri(sp[0],sp[1],sp[2], col[0],col[1],col[2]);
          tri:=tri+3;
        end;
      end;
    end
    else if o is TLine then
    begin
      ln:=TLine(o); lg:=ln.Geometry;
      if (lg<>nil) and (ln.Material<>nil) and (System.Length(lg.Pos)>=2) then
      begin
        base:=ln.Material.Color; lc:=Fogged(V3(base.r,base.g,base.b), o.Position.V);
        if o is TLineSegments then
        begin
          k:=0;
          while k+1<System.Length(lg.Pos) do
          begin
            a:=ToScreen(Mat4TransformPoint(mvp, lg.Pos[k]));
            bb:=ToScreen(Mat4TransformPoint(mvp, lg.Pos[k+1]));
            RasterLine(a, bb, lc.x, lc.y, lc.z, ln.Material.LineWidth);
            k:=k+2;
          end;
        end
        else
          for k:=0 to System.Length(lg.Pos)-2 do
          begin
            a:=ToScreen(Mat4TransformPoint(mvp, lg.Pos[k]));
            bb:=ToScreen(Mat4TransformPoint(mvp, lg.Pos[k+1]));
            RasterLine(a, bb, lc.x, lc.y, lc.z, ln.Material.LineWidth);
          end;
      end;
    end;
    for k:=0 to o.Children.Count-1 do RenderObject(TObject3D(o.Children[k]));
  end;

begin
  bg:=scene.Background;
  for i:=0 to FW*FH-1 do
  begin
    Pixels[i*4+0]:=ClampB(bg.r); Pixels[i*4+1]:=ClampB(bg.g);
    Pixels[i*4+2]:=ClampB(bg.b); Pixels[i*4+3]:=255; FZ[i]:=1e30;
  end;
  vp:=Mat4Multiply(camera.ProjectionMatrix, camera.ViewMatrix);
  camPos:=camera.Position.V;
  ambient:=V3(0,0,0); SetLength(dirs,0); SetLength(dcols,0);
  SetLength(plpos,0); SetLength(plcol,0); SetLength(plrange,0);
  CollectLights(scene);
  RenderObject(scene);
end;

procedure TWebGLRenderer.SaveBMP(const fn: string);
var f: file; hdr: array[0..53] of Byte; row, col, i, rowsize, pad, datasize: Integer; bt: Byte;
begin
  rowsize:=FW*3; pad:=(4-(rowsize mod 4)) mod 4; datasize:=(rowsize+pad)*FH;
  FillChar(hdr,SizeOf(hdr),0); hdr[0]:=$42; hdr[1]:=$4D; i:=54+datasize; Move(i,hdr[2],4);
  i:=54; Move(i,hdr[10],4); i:=40; Move(i,hdr[14],4);
  Move(FW,hdr[18],4); Move(FH,hdr[22],4); hdr[26]:=1; hdr[28]:=24; Move(datasize,hdr[34],4);
  AssignFile(f,fn); Rewrite(f,1); BlockWrite(f,hdr,54);
  for row:=FH-1 downto 0 do
  begin
    for col:=0 to FW-1 do
    begin i:=(row*FW+col)*4;
      bt:=Pixels[i+2]; BlockWrite(f,bt,1); bt:=Pixels[i+1]; BlockWrite(f,bt,1); bt:=Pixels[i+0]; BlockWrite(f,bt,1);
    end;
    bt:=0; for col:=1 to pad do BlockWrite(f,bt,1);
  end;
  CloseFile(f);
end;

end.
