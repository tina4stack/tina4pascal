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
  TV2 = record u, v: Single; end;                   // texture coord
  TMat4 = record m: array[0..15] of Single; end;    // column-major, like three/GL

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

  { an RGBA pixel buffer — three.Texture / CanvasTexture / VideoTexture live here.
    v0.3 has a built-in 5x7 font so labels work without an OS font engine. }
  TTexture = class
    Width, Height: Integer;
    Data: array of Byte;                             // RGBA, top-down
    constructor Create(w, h: Integer);
    procedure Fill(r, g, b, a: Byte);
    procedure SetPixel(x, y: Integer; r, g, b, a: Byte);
    procedure DrawText(const s: string; px, py, scale: Integer; r, g, b, a: Byte);
    procedure SetRGBA(src: PByte);                   // upload a frame (VideoTexture)
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

  { non-indexed triangle soup: position + normal (+ optional UV) per vertex }
  TBufferGeometry = class
    Pos: array of TV3;
    Normals: array of TV3;
    UV: array of TV2;                                      // len 0 = untextured
    BCx, BCy, BCz, BR: Single; BHasBounds: Boolean;        // bounding sphere (frustum cull)
    procedure PushTri(const a, b, c: TV3);                 // flat: one face normal
    procedure PushTriN(const a, b, c, na, nb, nc: TV3);    // smooth: per-vertex normals
    procedure PushUV(const a, b, c: TV2);                  // append 3 texcoords
    procedure EnsureBounds;                                // compute the bounding sphere once
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
  TCircleGeometry = class(TBufferGeometry)                 // XY plane, +Z normal
    constructor Create(radius: Single = 1; segments: Integer = 24);
  end;
  TRingGeometry = class(TBufferGeometry)
    constructor Create(innerR: Single = 0.5; outerR: Single = 1; segments: Integer = 24);
  end;
  TTorusGeometry = class(TBufferGeometry)
    constructor Create(radius: Single = 1; tube: Single = 0.4; ringSeg: Integer = 16; tubeSeg: Integer = 24);
  end;
  TIcosahedronGeometry = class(TBufferGeometry)           // 20 faces, flat-shaded
    constructor Create(radius: Single = 1; detail: Integer = 0);
  end;

  { line geometry: a flat list of vertices (LineSegments = pairs; Line = strip) }
  TLineGeometry = class
    Pos: array of TV3;
    procedure Push(x, y, z: Single);
    procedure PushV(const p: TV3);
  end;

  TMaterialSide = (msFront, msBack, msDouble);             // three.Material.side

  TMaterial = class
    Color: TColor;
    Map: TTexture;                                         // nil = untextured
    Side: TMaterialSide;                                   // default double (no cull)
    Wireframe: Boolean;
    Opacity: Single;
    Transparent: Boolean;                                  // three.Material.transparent — alpha-blend, no depth write
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

  { one geometry drawn many times with per-instance transforms (three.InstancedMesh) }
  TInstancedMesh = class(TObject3D)
    Geometry: TBufferGeometry;
    Material: TMaterial;
    Count: Integer;
    Matrices: array of TMat4;
    constructor Create(ageometry: TBufferGeometry; amaterial: TMaterial; acount: Integer);
    procedure SetMatrixAt(i: Integer; const m: TMat4);
    procedure SetInstance(i: Integer; const pos, rotEuler, scl: TV3);
  end;

  TLine = class(TObject3D)                                 // connected polyline
    Geometry: TLineGeometry;
    Material: TLineBasicMaterial;
    constructor Create(ageometry: TLineGeometry; amaterial: TLineBasicMaterial);
  end;
  TLineSegments = class(TLine);                            // vertex pairs

  TSpriteMaterial = class(TMaterial)
    Map: TTexture;                                         // nil = solid Color
    SizeAttenuation: Boolean;                             // true: shrink with distance
    constructor Create(amap: TTexture = nil; acolor: LongWord = $ffffff);
  end;

  { a camera-facing billboard — name tags, node labels, icons }
  TSprite = class(TObject3D)
    Material: TSpriteMaterial;
    constructor Create(amaterial: TSpriteMaterial);
  end;

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

  { ---- keyframe animation (three.AnimationClip / KeyframeTrack / AnimationMixer) ---- }
  TTrackTarget = (ttPosition, ttRotation, ttScale);   // which Object3D vector the track drives

  TKeyframeTrack = class
    ObjName: string;                                  // target object by name
    Target: TTrackTarget;
    Times: array of Single;
    Values: array of TV3;
    constructor Create(const aobjName: string; atarget: TTrackTarget);
    procedure AddKey(t: Single; const v: TV3);
    function Sample(t: Single): TV3;                  // linear interpolation, clamped
  end;

  TAnimationClip = class
    Name: string;
    Duration: Single;
    Tracks: TList;                                    // of TKeyframeTrack
    constructor Create(const aname: string; aduration: Single);
    function AddTrack(tr: TKeyframeTrack): TKeyframeTrack;
  end;

  TAnimationMixer = class
    Root: TObject3D;
    Clip: TAnimationClip;                             // v0.5: one active clip
    Time: Single;
    Loop: Boolean;
    constructor Create(aroot: TObject3D);
    procedure Play(aclip: TAnimationClip);            // three: clipAction(clip).play()
    procedure Apply;                                  // sample tracks at Time → objects
    procedure Update(dt: Single);                     // advance Time (loop) + Apply
  end;

  TWebGLRenderer = class
  private
    FW, FH: Integer;                                       // output size
    FSW, FSH, FSS: Integer;                                // supersampled size + factor
    FWK: array of Byte;                                    // 3D renders here (supersampled)
    FZ: array of Single;                                   // depth (supersampled)
    FBlend: Boolean;                                       // current material is transparent
    FBlendA: Single;                                       // its opacity (src alpha) for the blend
    procedure PlotDepth(px, py: Integer; z, r, g, b: Single);
    procedure RasterTri(const a, b, c, ca, cb, cc: TV3);   // screen x/y/ndc-z + per-vertex RGB
    procedure RasterTriTex(const a, b, c: TV3; const ta, tb, tc: TV2;
                           const la, lb, lc: TV3; tex: TTexture);   // textured + per-vertex light
    procedure RasterLine(const a, b: TV3; r, g, b2: Single; w: Integer);
    procedure Downsample;                                  // FWK → Pixels (box filter, AA)
    procedure FXAA;                                        // cheap post-process edge AA
  public
    EdgeAA: Boolean;                                       // cheap edge AA at samples=1
    Pixels: array of Byte;                                 // RGBA output, FW*FH*4
    constructor Create(width, height: Integer; samples: Integer = 2);
    procedure SetSize(width, height: Integer);
    procedure SetSamples(n: Integer);                      // 1 = fast, 2+ = anti-aliased
    property Samples: Integer read FSS;
    procedure Render(scene: TScene; camera: TCamera);
    { 2D overlay pass — draw the HUD on top of the 3D (the HTML layer's role) }
    procedure FillRectPx(x, y, w, h: Integer; r, g, b: Byte; a: Single);
    procedure StrokeRectPx(x, y, w, h, t: Integer; r, g, b: Byte; a: Single);
    procedure DrawTextPx(x, y: Integer; const s: string; scale: Integer; r, g, b: Byte);
    procedure SaveBMP(const fn: string);
    property Width: Integer read FW;
    property Height: Integer read FH;
  end;

function V3(x, y, z: Single): TV3;
function MkUV(u, v: Single): TV2;
function Mat4Identity: TMat4;
function Mat4Multiply(const a, b: TMat4): TMat4;
function Mat4Perspective(fovYdeg, aspect, near, far: Single): TMat4;
function Mat4Ortho(l, r, t, b, n, f: Single): TMat4;
function Mat4LookAt(const eye, center, up: TV3): TMat4;
function Mat4Compose(const pos, rotEuler, scl: TV3): TMat4;
function Mat4TransformPoint(const mat: TMat4; const p: TV3): TV3;
function Mat4TransformDir(const mat: TMat4; const d: TV3): TV3;
function Mat4Invert(const a: TMat4): TMat4;

{ convenience: a label texture sized to the text, drawn in fg over bg }
function MakeLabelTexture(const s: string; scale: Integer; fg, bg: LongWord; bgAlpha: Byte): TTexture;
{ a Sprite showing that label — anchor above a world point }
function MakeLabel(const s: string; scale: Integer; fg, bg: LongWord; bgAlpha: Byte): TSprite;

implementation

var GWhite: TColor = nil;                            // lazy white base for texture lighting

{ ============================ value math ============================ }

function V3(x, y, z: Single): TV3; begin Result.x:=x; Result.y:=y; Result.z:=z; end;
function MkUV(u, v: Single): TV2; begin Result.u:=u; Result.v:=v; end;
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

{ ---- built-in 5x7 bitmap font (uppercase, digits, a few symbols) ---- }
type TGlyphDef = record ch: Char; rows: array[0..6] of string; end;
const GLYPHS: array[0..40] of TGlyphDef = (
  (ch:' '; rows:('00000','00000','00000','00000','00000','00000','00000')),
  (ch:'A'; rows:('01110','10001','10001','11111','10001','10001','10001')),
  (ch:'B'; rows:('11110','10001','10001','11110','10001','10001','11110')),
  (ch:'C'; rows:('01110','10001','10000','10000','10000','10001','01110')),
  (ch:'D'; rows:('11100','10010','10001','10001','10001','10010','11100')),
  (ch:'E'; rows:('11111','10000','10000','11110','10000','10000','11111')),
  (ch:'F'; rows:('11111','10000','10000','11110','10000','10000','10000')),
  (ch:'G'; rows:('01110','10001','10000','10111','10001','10001','01111')),
  (ch:'H'; rows:('10001','10001','10001','11111','10001','10001','10001')),
  (ch:'I'; rows:('01110','00100','00100','00100','00100','00100','01110')),
  (ch:'J'; rows:('00111','00010','00010','00010','00010','10010','01100')),
  (ch:'K'; rows:('10001','10010','10100','11000','10100','10010','10001')),
  (ch:'L'; rows:('10000','10000','10000','10000','10000','10000','11111')),
  (ch:'M'; rows:('10001','11011','10101','10101','10001','10001','10001')),
  (ch:'N'; rows:('10001','10001','11001','10101','10011','10001','10001')),
  (ch:'O'; rows:('01110','10001','10001','10001','10001','10001','01110')),
  (ch:'P'; rows:('11110','10001','10001','11110','10000','10000','10000')),
  (ch:'Q'; rows:('01110','10001','10001','10001','10101','10010','01101')),
  (ch:'R'; rows:('11110','10001','10001','11110','10100','10010','10001')),
  (ch:'S'; rows:('01111','10000','10000','01110','00001','00001','11110')),
  (ch:'T'; rows:('11111','00100','00100','00100','00100','00100','00100')),
  (ch:'U'; rows:('10001','10001','10001','10001','10001','10001','01110')),
  (ch:'V'; rows:('10001','10001','10001','10001','10001','01010','00100')),
  (ch:'W'; rows:('10001','10001','10001','10101','10101','11011','10001')),
  (ch:'X'; rows:('10001','10001','01010','00100','01010','10001','10001')),
  (ch:'Y'; rows:('10001','10001','01010','00100','00100','00100','00100')),
  (ch:'Z'; rows:('11111','00001','00010','00100','01000','10000','11111')),
  (ch:'0'; rows:('01110','10001','10011','10101','11001','10001','01110')),
  (ch:'1'; rows:('00100','01100','00100','00100','00100','00100','01110')),
  (ch:'2'; rows:('01110','10001','00001','00010','00100','01000','11111')),
  (ch:'3'; rows:('11111','00010','00100','00010','00001','10001','01110')),
  (ch:'4'; rows:('00010','00110','01010','10010','11111','00010','00010')),
  (ch:'5'; rows:('11111','10000','11110','00001','00001','10001','01110')),
  (ch:'6'; rows:('00110','01000','10000','11110','10001','10001','01110')),
  (ch:'7'; rows:('11111','00001','00010','00100','01000','01000','01000')),
  (ch:'8'; rows:('01110','10001','10001','01110','10001','10001','01110')),
  (ch:'9'; rows:('01110','10001','10001','01111','00001','00010','01100')),
  (ch:'-'; rows:('00000','00000','00000','11111','00000','00000','00000')),
  (ch:':'; rows:('00000','00100','00100','00000','00100','00100','00000')),
  (ch:'.'; rows:('00000','00000','00000','00000','00000','00100','00100')),
  (ch:'#'; rows:('01010','11111','01010','01010','11111','01010','00000'))
);

function GlyphIndex(ch: Char): Integer;
var i: Integer;
begin
  Result:=-1;
  for i:=0 to High(GLYPHS) do if GLYPHS[i].ch=ch then Exit(i);
end;

{ ---- TTexture ---- }
constructor TTexture.Create(w, h: Integer);
begin Width:=w; Height:=h; SetLength(Data, w*h*4); Fill(0,0,0,0); end;

procedure TTexture.Fill(r, g, b, a: Byte);
var i: Integer;
begin for i:=0 to Width*Height-1 do begin Data[i*4]:=r; Data[i*4+1]:=g; Data[i*4+2]:=b; Data[i*4+3]:=a; end; end;

procedure TTexture.SetPixel(x, y: Integer; r, g, b, a: Byte);
var i: Integer;
begin
  if (x<0) or (y<0) or (x>=Width) or (y>=Height) then Exit;
  i:=(y*Width+x)*4; Data[i]:=r; Data[i+1]:=g; Data[i+2]:=b; Data[i+3]:=a;
end;

procedure TTexture.DrawText(const s: string; px, py, scale: Integer; r, g, b, a: Byte);
var i, gi, rr, cc, sx, sy, cx: Integer; ch: Char; rowstr: string;
begin
  cx:=px;
  for i:=1 to System.Length(s) do
  begin
    ch:=UpCase(s[i]); gi:=GlyphIndex(ch);
    if gi>=0 then
      for rr:=0 to 6 do
      begin
        rowstr:=GLYPHS[gi].rows[rr];
        for cc:=0 to 4 do
          if rowstr[cc+1]='1' then
            for sy:=0 to scale-1 do for sx:=0 to scale-1 do
              SetPixel(cx+cc*scale+sx, py+rr*scale+sy, r,g,b,a);
      end;
    cx:=cx+6*scale;                                  // 5px glyph + 1px gap
  end;
end;

procedure TTexture.SetRGBA(src: PByte);
begin if src<>nil then Move(src^, Data[0], Width*Height*4); end;

function MakeLabelTexture(const s: string; scale: Integer; fg, bg: LongWord; bgAlpha: Byte): TTexture;
var w, h, pad: Integer;
begin
  pad:=2*scale;
  w:=System.Length(s)*6*scale + pad*2; if w<1 then w:=1;
  h:=7*scale + pad*2;
  Result:=TTexture.Create(w, h);
  Result.Fill((bg shr 16) and $ff, (bg shr 8) and $ff, bg and $ff, bgAlpha);
  Result.DrawText(s, pad, pad, scale, (fg shr 16) and $ff, (fg shr 8) and $ff, fg and $ff, 255);
end;

function MakeLabel(const s: string; scale: Integer; fg, bg: LongWord; bgAlpha: Byte): TSprite;
var tex: TTexture; asp: Single;
begin
  tex:=MakeLabelTexture(s, scale, fg, bg, bgAlpha);
  Result:=TSprite.Create(TSpriteMaterial.Create(tex));
  asp:=tex.Width/tex.Height;
  Result.Scale.SetXYZ(0.7*asp, 0.7, 1);              // sensible default world size
end;

constructor TSpriteMaterial.Create(amap: TTexture; acolor: LongWord);
begin inherited Create(acolor); Map:=amap; SizeAttenuation:=True; end;

constructor TSprite.Create(amaterial: TSpriteMaterial);
begin inherited Create; Material:=amaterial; end;

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

procedure TBufferGeometry.PushUV(const a, b, c: TV2);
var i: Integer;
begin
  i:=System.Length(UV); SetLength(UV,i+3); UV[i]:=a; UV[i+1]:=b; UV[i+2]:=c;
end;

procedure TBufferGeometry.EnsureBounds;
var i: Integer; mnx,mny,mnz,mxx,mxy,mxz,dx,dy,dz,d: Single;
begin
  if BHasBounds then Exit; BHasBounds:=True;
  if System.Length(Pos)=0 then begin BCx:=0; BCy:=0; BCz:=0; BR:=0; Exit; end;
  mnx:=Pos[0].x; mny:=Pos[0].y; mnz:=Pos[0].z; mxx:=mnx; mxy:=mny; mxz:=mnz;
  for i:=1 to High(Pos) do
  begin
    if Pos[i].x<mnx then mnx:=Pos[i].x; if Pos[i].x>mxx then mxx:=Pos[i].x;
    if Pos[i].y<mny then mny:=Pos[i].y; if Pos[i].y>mxy then mxy:=Pos[i].y;
    if Pos[i].z<mnz then mnz:=Pos[i].z; if Pos[i].z>mxz then mxz:=Pos[i].z;
  end;
  BCx:=(mnx+mxx)/2; BCy:=(mny+mxy)/2; BCz:=(mnz+mxz)/2; BR:=0;
  for i:=0 to High(Pos) do
  begin dx:=Pos[i].x-BCx; dy:=Pos[i].y-BCy; dz:=Pos[i].z-BCz; d:=dx*dx+dy*dy+dz*dz; if d>BR then BR:=d; end;
  BR:=Sqrt(BR);
end;

function MaxScaleOf(const m: TMat4): Single;
var s1, s2: Single;
begin
  Result:=Sqrt(m.m[0]*m.m[0]+m.m[1]*m.m[1]+m.m[2]*m.m[2]);
  s1:=Sqrt(m.m[4]*m.m[4]+m.m[5]*m.m[5]+m.m[6]*m.m[6]);
  s2:=Sqrt(m.m[8]*m.m[8]+m.m[9]*m.m[9]+m.m[10]*m.m[10]);
  if s1>Result then Result:=s1; if s2>Result then Result:=s2;
end;

constructor TBoxGeometry.Create(w, h, d: Single);
var hx, hy, hz: Single;
  procedure Quad(const a,b,c,dd: TV3);
  begin
    PushTri(a,b,c);  PushUV(MkUV(0,1), MkUV(1,1), MkUV(1,0));
    PushTri(a,c,dd); PushUV(MkUV(0,1), MkUV(1,0), MkUV(0,0));
  end;
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
  PushTri(V3(-hx,-hy,0),V3(hx,-hy,0),V3(hx,hy,0));   PushUV(MkUV(0,1),MkUV(1,1),MkUV(1,0));
  PushTri(V3(-hx,-hy,0),V3(hx,hy,0),V3(-hx,hy,0));   PushUV(MkUV(0,1),MkUV(1,0),MkUV(0,0));
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
    { side — wound CCW-outward (three.js convention) so material.side=FrontSide
      culls the far half, not the near one (skip degenerate edge at a 0 radius) }
    if radiusTop>1e-6 then PushTriN(t0,b1,b0, nt0,nt1,nt0);
    if radiusBottom>1e-6 then PushTriN(t0,t1,b1, nt0,nt1,nt1);
    if (radiusTop<=1e-6) then PushTriN(t0,b1,b0, VNorm(VAdd(nt0,nt1)),nt1,nt0);
    { caps (flat) }
    if radiusTop>1e-6 then PushTri(cT, t1, t0);
    if radiusBottom>1e-6 then PushTri(cB, b0, b1);
  end;
end;

constructor TConeGeometry.Create(radius, height: Single; radialSeg: Integer);
begin inherited Create(0, radius, height, radialSeg); end;

constructor TCircleGeometry.Create(radius: Single; segments: Integer);
var i: Integer; a0, a1: Single; n: TV3;
begin
  inherited Create; n:=V3(0,0,1);
  for i:=0 to segments-1 do
  begin
    a0:=(i/segments)*2*Pi; a1:=((i+1)/segments)*2*Pi;
    PushTriN(V3(0,0,0), V3(radius*Cos(a0),radius*Sin(a0),0), V3(radius*Cos(a1),radius*Sin(a1),0), n,n,n);
    PushUV(MkUV(0.5,0.5), MkUV(0.5+0.5*Cos(a0),0.5-0.5*Sin(a0)), MkUV(0.5+0.5*Cos(a1),0.5-0.5*Sin(a1)));
  end;
end;

constructor TRingGeometry.Create(innerR, outerR: Single; segments: Integer);
var i: Integer; a0, a1: Single; n, i0, i1, o0, o1: TV3;
begin
  inherited Create; n:=V3(0,0,1);
  for i:=0 to segments-1 do
  begin
    a0:=(i/segments)*2*Pi; a1:=((i+1)/segments)*2*Pi;
    i0:=V3(innerR*Cos(a0),innerR*Sin(a0),0); i1:=V3(innerR*Cos(a1),innerR*Sin(a1),0);
    o0:=V3(outerR*Cos(a0),outerR*Sin(a0),0); o1:=V3(outerR*Cos(a1),outerR*Sin(a1),0);
    PushTriN(i0,o0,o1, n,n,n); PushUV(MkUV(0,0),MkUV(1,0),MkUV(1,1));
    PushTriN(i0,o1,i1, n,n,n); PushUV(MkUV(0,0),MkUV(1,1),MkUV(0,1));
  end;
end;

constructor TIcosahedronGeometry.Create(radius: Single; detail: Integer);
const
  gr = 1.618033988749895;
  faces: array[0..19,0..2] of Integer =
    ((0,11,5),(0,5,1),(0,1,7),(0,7,10),(0,10,11),
     (1,5,9),(5,11,4),(11,10,2),(10,7,6),(7,1,8),
     (3,9,4),(3,4,2),(3,2,6),(3,6,8),(3,8,9),
     (4,9,5),(2,4,11),(6,2,10),(8,6,7),(9,8,1));
var v: array[0..11] of TV3; i: Integer;
  function NV(x, y, z: Single): TV3; begin Result:=VScale(VNorm(V3(x,y,z)), radius); end;
begin
  inherited Create;
  v[0]:=NV(-1,gr,0); v[1]:=NV(1,gr,0); v[2]:=NV(-1,-gr,0); v[3]:=NV(1,-gr,0);
  v[4]:=NV(0,-1,gr); v[5]:=NV(0,1,gr); v[6]:=NV(0,-1,-gr); v[7]:=NV(0,1,-gr);
  v[8]:=NV(gr,0,-1); v[9]:=NV(gr,0,1); v[10]:=NV(-gr,0,-1); v[11]:=NV(-gr,0,1);
  for i:=0 to 19 do PushTri(v[faces[i,0]], v[faces[i,1]], v[faces[i,2]]);
end;

constructor TTorusGeometry.Create(radius, tube: Single; ringSeg, tubeSeg: Integer);
var i, j: Integer; u0, u1, v0, v1: Single;
  function TP(u, v: Single): TV3;
  begin Result:=V3((radius+tube*Cos(v))*Cos(u), (radius+tube*Cos(v))*Sin(u), tube*Sin(v)); end;
  function TN(u, v: Single): TV3;
  begin Result:=VNorm(V3(Cos(v)*Cos(u), Cos(v)*Sin(u), Sin(v))); end;
begin
  inherited Create;
  for i:=0 to ringSeg-1 do
    for j:=0 to tubeSeg-1 do
    begin
      u0:=(i/ringSeg)*2*Pi; u1:=((i+1)/ringSeg)*2*Pi;
      v0:=(j/tubeSeg)*2*Pi; v1:=((j+1)/tubeSeg)*2*Pi;
      PushTriN(TP(u0,v0),TP(u1,v0),TP(u1,v1), TN(u0,v0),TN(u1,v0),TN(u1,v1));
      PushTriN(TP(u0,v0),TP(u1,v1),TP(u0,v1), TN(u0,v0),TN(u1,v1),TN(u0,v1));
    end;
end;

procedure TLineGeometry.Push(x, y, z: Single);
var i: Integer; begin i:=System.Length(Pos); SetLength(Pos,i+1); Pos[i]:=V3(x,y,z); end;
procedure TLineGeometry.PushV(const p: TV3);
var i: Integer; begin i:=System.Length(Pos); SetLength(Pos,i+1); Pos[i]:=p; end;

{ ============================ materials / objects / lights ============================ }

constructor TMaterial.Create(acolor: LongWord);
begin Color:=TColor.Create(acolor); Map:=nil; Side:=msDouble; Wireframe:=False; Opacity:=1; Transparent:=False; end;
constructor TMeshPhongMaterial.Create(acolor: LongWord);
begin inherited Create(acolor); Shininess:=30; end;
constructor TLineBasicMaterial.Create(acolor: LongWord);
begin inherited Create(acolor); LineWidth:=1; end;

constructor TMesh.Create(ageometry: TBufferGeometry; amaterial: TMaterial);
begin inherited Create; Geometry:=ageometry; Material:=amaterial; end;

constructor TInstancedMesh.Create(ageometry: TBufferGeometry; amaterial: TMaterial; acount: Integer);
var i: Integer;
begin
  inherited Create; Geometry:=ageometry; Material:=amaterial; Count:=acount;
  SetLength(Matrices, acount);
  for i:=0 to acount-1 do Matrices[i]:=Mat4Identity;
end;
procedure TInstancedMesh.SetMatrixAt(i: Integer; const m: TMat4);
begin if (i>=0) and (i<Count) then Matrices[i]:=m; end;
procedure TInstancedMesh.SetInstance(i: Integer; const pos, rotEuler, scl: TV3);
begin if (i>=0) and (i<Count) then Matrices[i]:=Mat4Compose(pos, rotEuler, scl); end;
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

{ ============================ animation ============================ }

constructor TKeyframeTrack.Create(const aobjName: string; atarget: TTrackTarget);
begin ObjName:=aobjName; Target:=atarget; end;

procedure TKeyframeTrack.AddKey(t: Single; const v: TV3);
var i: Integer;
begin
  i:=System.Length(Times); SetLength(Times,i+1); SetLength(Values,i+1);
  Times[i]:=t; Values[i]:=v;
end;

function TKeyframeTrack.Sample(t: Single): TV3;
var n, i: Integer; f: Single;
begin
  n:=System.Length(Times);
  if n=0 then begin Result:=V3(0,0,0); Exit; end;
  if t<=Times[0] then begin Result:=Values[0]; Exit; end;
  if t>=Times[n-1] then begin Result:=Values[n-1]; Exit; end;
  for i:=0 to n-2 do
    if (t>=Times[i]) and (t<=Times[i+1]) then
    begin
      f:=(t-Times[i])/(Times[i+1]-Times[i]);
      Result:=V3(Values[i].x+(Values[i+1].x-Values[i].x)*f,
                 Values[i].y+(Values[i+1].y-Values[i].y)*f,
                 Values[i].z+(Values[i+1].z-Values[i].z)*f);
      Exit;
    end;
  Result:=Values[n-1];
end;

constructor TAnimationClip.Create(const aname: string; aduration: Single);
begin Name:=aname; Duration:=aduration; Tracks:=TList.Create; end;
function TAnimationClip.AddTrack(tr: TKeyframeTrack): TKeyframeTrack;
begin Tracks.Add(tr); Result:=tr; end;

function FindObjByName(o: TObject3D; const n: string): TObject3D;
var k: Integer;
begin
  Result:=nil;
  if o=nil then Exit;
  if o.Name=n then Exit(o);
  for k:=0 to o.Children.Count-1 do
  begin Result:=FindObjByName(TObject3D(o.Children[k]), n); if Result<>nil then Exit; end;
end;

constructor TAnimationMixer.Create(aroot: TObject3D);
begin Root:=aroot; Clip:=nil; Time:=0; Loop:=True; end;
procedure TAnimationMixer.Play(aclip: TAnimationClip);
begin Clip:=aclip; Time:=0; end;

procedure TAnimationMixer.Apply;
var i: Integer; tr: TKeyframeTrack; obj: TObject3D; v: TV3;
begin
  if Clip=nil then Exit;
  for i:=0 to Clip.Tracks.Count-1 do
  begin
    tr:=TKeyframeTrack(Clip.Tracks[i]);
    obj:=FindObjByName(Root, tr.ObjName);
    if obj=nil then Continue;
    v:=tr.Sample(Time);
    case tr.Target of
      ttPosition: obj.Position.SetXYZ(v.x, v.y, v.z);
      ttRotation: obj.Rotation.SetXYZ(v.x, v.y, v.z);
      ttScale:    obj.Scale.SetXYZ(v.x, v.y, v.z);
    end;
  end;
end;

procedure TAnimationMixer.Update(dt: Single);
begin
  Time:=Time+dt;
  if Loop and (Clip<>nil) and (Clip.Duration>0) then
    while Time>Clip.Duration do Time:=Time-Clip.Duration;
  Apply;
end;

{ ============================ near-plane clipping ============================ }

type
  TV4C = record x, y, z, w: Single; end;                  // homogeneous clip coord
  TClipV = record c: TV4C; col: TV3; uv: TV2; end;        // + interpolated payload

function Mat4Mul4(const m: TMat4; const p: TV3): TV4C;    // NO perspective divide
begin
  Result.x:=m.m[0]*p.x+m.m[4]*p.y+m.m[8]*p.z+m.m[12];
  Result.y:=m.m[1]*p.x+m.m[5]*p.y+m.m[9]*p.z+m.m[13];
  Result.z:=m.m[2]*p.x+m.m[6]*p.y+m.m[10]*p.z+m.m[14];
  Result.w:=m.m[3]*p.x+m.m[7]*p.y+m.m[11]*p.z+m.m[15];
end;

function LerpClipV(const a, b: TClipV; t: Single): TClipV;
begin
  Result.c.x:=a.c.x+(b.c.x-a.c.x)*t; Result.c.y:=a.c.y+(b.c.y-a.c.y)*t;
  Result.c.z:=a.c.z+(b.c.z-a.c.z)*t; Result.c.w:=a.c.w+(b.c.w-a.c.w)*t;
  Result.col:=V3(a.col.x+(b.col.x-a.col.x)*t, a.col.y+(b.col.y-a.col.y)*t, a.col.z+(b.col.z-a.col.z)*t);
  Result.uv.u:=a.uv.u+(b.uv.u-a.uv.u)*t; Result.uv.v:=a.uv.v+(b.uv.v-a.uv.v)*t;
end;

{ Sutherland–Hodgman against the near plane (z + w >= 0); 3 in, up to 4 out }
procedure ClipNear(const inv: array of TClipV; out outv: array of TClipV; out outc: Integer);
var i: Integer; cur, nxt: TClipV; dcur, dnxt, t: Single; insC, insN: Boolean;
begin
  outc:=0;
  for i:=0 to 2 do
  begin
    cur:=inv[i]; nxt:=inv[(i+1) mod 3];
    dcur:=cur.c.z+cur.c.w; dnxt:=nxt.c.z+nxt.c.w;
    insC:=dcur>=0; insN:=dnxt>=0;
    if insC then begin outv[outc]:=cur; Inc(outc); end;
    if insC<>insN then
    begin t:=dcur/(dcur-dnxt); outv[outc]:=LerpClipV(cur,nxt,t); Inc(outc); end;
  end;
end;

{ ============================ software renderer ============================ }

constructor TWebGLRenderer.Create(width, height: Integer; samples: Integer);
begin if samples<1 then samples:=1; if samples>4 then samples:=4; FSS:=samples; SetSize(width, height); end;
procedure TWebGLRenderer.SetSize(width, height: Integer);
begin
  if FSS<1 then FSS:=2;
  FW:=width; FH:=height; FSW:=FW*FSS; FSH:=FH*FSS;
  SetLength(Pixels,FW*FH*4); SetLength(FWK,FSW*FSH*4); SetLength(FZ,FSW*FSH);
end;

procedure TWebGLRenderer.SetSamples(n: Integer);
begin
  if n<1 then n:=1; if n>4 then n:=4;
  if n=FSS then Exit; FSS:=n; SetSize(FW, FH);
end;

{ box-filter the supersampled buffer down into the output — anti-aliasing }
procedure TWebGLRenderer.Downsample;
var ox, oy, sx, sy, si, oi, a0, a1, a2, n: Integer;
begin
  if FSS<=1 then begin if System.Length(FWK)>0 then Move(FWK[0], Pixels[0], FW*FH*4); Exit; end;
  n:=FSS*FSS;
  for oy:=0 to FH-1 do
    for ox:=0 to FW-1 do
    begin
      a0:=0; a1:=0; a2:=0;
      for sy:=0 to FSS-1 do
        for sx:=0 to FSS-1 do
        begin
          si:=(((oy*FSS+sy)*FSW)+(ox*FSS+sx))*4;
          Inc(a0, FWK[si+0]); Inc(a1, FWK[si+1]); Inc(a2, FWK[si+2]);
        end;
      oi:=(oy*FW+ox)*4;
      Pixels[oi+0]:=a0 div n; Pixels[oi+1]:=a1 div n; Pixels[oi+2]:=a2 div n; Pixels[oi+3]:=255;
    end;
end;

{ FXAA — three.js's FXAAShader lineage: luma edge detect, then blend along the
  edge direction. One post pass over the output; non-edge pixels are skipped. }
procedure TWebGLRenderer.FXAA;
const TMIN=10; SPAN=4.0;
var src: array of Byte; lum: array of Byte; x, y, i, i4, p, n: Integer;
    lM, lNW, lNE, lSW, lSE, lMin, lMax, contrast, thr, lbi: Integer;
    dx, dy, dmin, rcp: Single;
    ar,ag,ab, br,bg,bb, s1r,s1g,s1b, s2r,s2g,s2b, s3r,s3g,s3b, s4r,s4g,s4b: Single;
  procedure Samp(fx, fy: Single; out r,g,b: Single);
  var x0,y0,x1,y1,j00,j10,j01,j11: Integer; tx,ty,w00,w10,w01,w11: Single;
  begin
    if fx<0 then fx:=0; if fx>FW-1 then fx:=FW-1; if fy<0 then fy:=0; if fy>FH-1 then fy:=FH-1;
    x0:=Trunc(fx); y0:=Trunc(fy); x1:=x0+1; if x1>FW-1 then x1:=FW-1; y1:=y0+1; if y1>FH-1 then y1:=FH-1;
    tx:=fx-x0; ty:=fy-y0;
    j00:=(y0*FW+x0)*4; j10:=(y0*FW+x1)*4; j01:=(y1*FW+x0)*4; j11:=(y1*FW+x1)*4;
    w00:=(1-tx)*(1-ty); w10:=tx*(1-ty); w01:=(1-tx)*ty; w11:=tx*ty;
    r:=src[j00]*w00+src[j10]*w10+src[j01]*w01+src[j11]*w11;
    g:=src[j00+1]*w00+src[j10+1]*w10+src[j01+1]*w01+src[j11+1]*w11;
    b:=src[j00+2]*w00+src[j10+2]*w10+src[j01+2]*w01+src[j11+2]*w11;
  end;
begin
  n:=FW*FH; if n=0 then Exit; SetLength(src,n*4); Move(Pixels[0],src[0],n*4);
  { one integer-luma pass; the edge loop then just reads it (no recompute) }
  SetLength(lum,n);
  for i:=0 to n-1 do lum[i]:=(77*src[i*4]+150*src[i*4+1]+29*src[i*4+2]) shr 8;
  for y:=1 to FH-2 do
  begin
    p:=y*FW;
    for x:=1 to FW-2 do
    begin
      i:=p+x;
      lM:=lum[i]; lNW:=lum[i-FW-1]; lNE:=lum[i-FW+1]; lSW:=lum[i+FW-1]; lSE:=lum[i+FW+1];
      lMin:=lM; if lNW<lMin then lMin:=lNW; if lNE<lMin then lMin:=lNE; if lSW<lMin then lMin:=lSW; if lSE<lMin then lMin:=lSE;
      lMax:=lM; if lNW>lMax then lMax:=lNW; if lNE>lMax then lMax:=lNE; if lSW>lMax then lMax:=lSW; if lSE>lMax then lMax:=lSE;
      contrast:=lMax-lMin; thr:=lMax shr 3; if thr<TMIN then thr:=TMIN;
      if contrast<thr then Continue;                          // flat — leave sharp
      dx:=-((lNW+lNE)-(lSW+lSE)); dy:=((lNW+lSW)-(lNE+lSE));   // edge direction
      dmin:=(lNW+lNE+lSW+lSE)*0.03125; if dmin<2 then dmin:=2;
      rcp:=1.0/(Min(Abs(dx),Abs(dy))+dmin); dx:=dx*rcp; dy:=dy*rcp;
      if dx>SPAN then dx:=SPAN; if dx<-SPAN then dx:=-SPAN;
      if dy>SPAN then dy:=SPAN; if dy<-SPAN then dy:=-SPAN;
      Samp(x-dx*0.16667, y-dy*0.16667, s1r,s1g,s1b);
      Samp(x+dx*0.16667, y+dy*0.16667, s2r,s2g,s2b);
      ar:=0.5*(s1r+s2r); ag:=0.5*(s1g+s2g); ab:=0.5*(s1b+s2b);
      Samp(x-dx*0.5, y-dy*0.5, s3r,s3g,s3b);
      Samp(x+dx*0.5, y+dy*0.5, s4r,s4g,s4b);
      br:=ar*0.5+0.25*(s3r+s4r); bg:=ag*0.5+0.25*(s3g+s4g); bb:=ab*0.5+0.25*(s3b+s4b);
      lbi:=(77*Round(br)+150*Round(bg)+29*Round(bb)) shr 8;
      i4:=i*4;
      if (lbi<lMin) or (lbi>lMax) then begin Pixels[i4]:=Round(ar); Pixels[i4+1]:=Round(ag); Pixels[i4+2]:=Round(ab); end
      else begin Pixels[i4]:=Round(br); Pixels[i4+1]:=Round(bg); Pixels[i4+2]:=Round(bb); end;
    end;
  end;
end;

function ClampB(v: Single): Byte;
begin if v<0 then v:=0; if v>1 then v:=1; Result:=Round(v*255); end;

procedure TWebGLRenderer.PlotDepth(px, py: Integer; z, r, g, b: Single);
var idx: Integer;
begin
  if (px<0) or (py<0) or (px>=FSW) or (py>=FSH) then Exit;
  idx:=py*FSW+px;
  if z<FZ[idx] then
  begin FZ[idx]:=z;
    FWK[idx*4+0]:=ClampB(r); FWK[idx*4+1]:=ClampB(g);
    FWK[idx*4+2]:=ClampB(b); FWK[idx*4+3]:=255;
  end;
end;

{ Gouraud triangle: a/b/c carry screen x,y and ndc z; ca/cb/cc are per-vertex RGB }
procedure TWebGLRenderer.RasterTri(const a, b, c, ca, cb, cc: TV3);
var minx, maxx, miny, maxy, px, py, idx: Integer;
    area, invA, A0,B0,C0, A1,B1,C1, A2,B2,C2, w0,w1,w2, n0,n1,n2, z: Single;
begin
  { edge functions E_i = A_i*x + B_i*y + C_i — computed once, stepped per pixel }
  A0:=c.y-b.y; B0:=b.x-c.x; C0:=-(A0*b.x+B0*b.y);
  A1:=a.y-c.y; B1:=c.x-a.x; C1:=-(A1*c.x+B1*c.y);
  A2:=b.y-a.y; B2:=a.x-b.x; C2:=-(A2*a.x+B2*a.y);
  area:=A2*c.x+B2*c.y+C2; if Abs(area)<1e-6 then Exit; invA:=1/area;
  minx:=Trunc(Min(a.x,Min(b.x,c.x))); maxx:=Trunc(Max(a.x,Max(b.x,c.x)))+1;
  miny:=Trunc(Min(a.y,Min(b.y,c.y))); maxy:=Trunc(Max(a.y,Max(b.y,c.y)))+1;
  if minx<0 then minx:=0; if miny<0 then miny:=0;
  if maxx>FSW then maxx:=FSW; if maxy>FSH then maxy:=FSH;
  for py:=miny to maxy-1 do
  begin
    w0:=A0*(minx+0.5)+B0*(py+0.5)+C0;
    w1:=A1*(minx+0.5)+B1*(py+0.5)+C1;
    w2:=A2*(minx+0.5)+B2*(py+0.5)+C2;
    idx:=py*FSW+minx;
    for px:=minx to maxx-1 do
    begin
      if ((w0>=0)and(w1>=0)and(w2>=0)) or ((w0<=0)and(w1<=0)and(w2<=0)) then
      begin
        n0:=w0*invA; n1:=w1*invA; n2:=w2*invA;
        z:=n0*a.z+n1*b.z+n2*c.z;
        if z<FZ[idx] then
        begin
          if FBlend then
          begin
            { transparent: src·a + dst·(1-a), depth-TESTED but not written, so
              stacked puffs blend and opaque geometry in front still occludes }
            FWK[idx*4+0]:=ClampB((n0*ca.x+n1*cb.x+n2*cc.x)*FBlendA + FWK[idx*4+0]/255*(1-FBlendA));
            FWK[idx*4+1]:=ClampB((n0*ca.y+n1*cb.y+n2*cc.y)*FBlendA + FWK[idx*4+1]/255*(1-FBlendA));
            FWK[idx*4+2]:=ClampB((n0*ca.z+n1*cb.z+n2*cc.z)*FBlendA + FWK[idx*4+2]/255*(1-FBlendA));
          end
          else
          begin FZ[idx]:=z;
            FWK[idx*4+0]:=ClampB(n0*ca.x+n1*cb.x+n2*cc.x);
            FWK[idx*4+1]:=ClampB(n0*ca.y+n1*cb.y+n2*cc.y);
            FWK[idx*4+2]:=ClampB(n0*ca.z+n1*cb.z+n2*cc.z);
            FWK[idx*4+3]:=255;
          end;
        end;
      end;
      w0:=w0+A0; w1:=w1+A1; w2:=w2+A2; Inc(idx);
    end;
  end;
end;

{ textured Gouraud triangle: interpolate UV + per-vertex light, sample the map }
procedure TWebGLRenderer.RasterTriTex(const a, b, c: TV3; const ta, tb, tc: TV2;
                                      const la, lb, lc: TV3; tex: TTexture);
var minx,maxx,miny,maxy,px,py,idx,txx,tyy,ti: Integer;
    area,invA,A0,B0,C0,A1,B1,C1,A2,B2,C2,w0,w1,w2,n0,n1,n2,z,uu,vv,cr,cg,cbl: Single;
begin
  if tex=nil then Exit;
  A0:=c.y-b.y; B0:=b.x-c.x; C0:=-(A0*b.x+B0*b.y);
  A1:=a.y-c.y; B1:=c.x-a.x; C1:=-(A1*c.x+B1*c.y);
  A2:=b.y-a.y; B2:=a.x-b.x; C2:=-(A2*a.x+B2*a.y);
  area:=A2*c.x+B2*c.y+C2; if Abs(area)<1e-6 then Exit; invA:=1/area;
  minx:=Trunc(Min(a.x,Min(b.x,c.x))); maxx:=Trunc(Max(a.x,Max(b.x,c.x)))+1;
  miny:=Trunc(Min(a.y,Min(b.y,c.y))); maxy:=Trunc(Max(a.y,Max(b.y,c.y)))+1;
  if minx<0 then minx:=0; if miny<0 then miny:=0;
  if maxx>FSW then maxx:=FSW; if maxy>FSH then maxy:=FSH;
  for py:=miny to maxy-1 do
  begin
    w0:=A0*(minx+0.5)+B0*(py+0.5)+C0; w1:=A1*(minx+0.5)+B1*(py+0.5)+C1; w2:=A2*(minx+0.5)+B2*(py+0.5)+C2;
    idx:=py*FSW+minx;
    for px:=minx to maxx-1 do
    begin
      if ((w0>=0)and(w1>=0)and(w2>=0)) or ((w0<=0)and(w1<=0)and(w2<=0)) then
      begin
        n0:=w0*invA; n1:=w1*invA; n2:=w2*invA;
        z:=n0*a.z+n1*b.z+n2*c.z;
        if z<FZ[idx] then
        begin
          uu:=n0*ta.u+n1*tb.u+n2*tc.u; vv:=n0*ta.v+n1*tb.v+n2*tc.v;
          txx:=Trunc(uu*tex.Width); tyy:=Trunc(vv*tex.Height);
          if txx<0 then txx:=0; if tyy<0 then tyy:=0;
          if txx>=tex.Width then txx:=tex.Width-1; if tyy>=tex.Height then tyy:=tex.Height-1;
          ti:=(tyy*tex.Width+txx)*4;
          cr:=n0*la.x+n1*lb.x+n2*lc.x; cg:=n0*la.y+n1*lb.y+n2*lc.y; cbl:=n0*la.z+n1*lb.z+n2*lc.z;
          FZ[idx]:=z;
          FWK[idx*4+0]:=ClampB(tex.Data[ti+0]/255*cr);
          FWK[idx*4+1]:=ClampB(tex.Data[ti+1]/255*cg);
          FWK[idx*4+2]:=ClampB(tex.Data[ti+2]/255*cbl);
          FWK[idx*4+3]:=255;
        end;
      end;
      w0:=w0+A0; w1:=w1+A1; w2:=w2+A2; Inc(idx);
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
  fp: array[0..5,0..3] of Single;            // 6 frustum planes (normalized)
  passTransparent: Boolean;                  // two-pass: opaque first, then transparent

  function SphereInFrustum(cx, cy, cz, r: Single): Boolean;
  var k: Integer;
  begin
    for k:=0 to 5 do
      if fp[k,0]*cx + fp[k,1]*cy + fp[k,2]*cz + fp[k,3] < -r then Exit(False);
    Result:=True;
  end;

  procedure SetP(idx: Integer; a, b, c, d: Single);
  var l: Single;
  begin l:=Sqrt(a*a+b*b+c*c); if l<1e-9 then l:=1;
    fp[idx,0]:=a/l; fp[idx,1]:=b/l; fp[idx,2]:=c/l; fp[idx,3]:=d/l; end;

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

  procedure RenderObject(o: TObject3D; const parentW: TMat4);
  var k, ii: Integer; mesh: TMesh; im: TInstancedMesh; ln: TLine; lg: TLineGeometry;
      worldM, mvp, localM, iw: TMat4; base: TColor; g: TBufferGeometry; bc: TV3; rr: Single;
      lc: TV3; a, bb: TV3;
      spr: TSprite; sm: TSpriteMaterial; stex: TTexture;
      wc, vpos, clip: TV3; cxf, cyf, depth, sw, pxu, pyu, hw, hh, uu, vv: Single;
      ix0, iy0, ix1, iy1, xx, yy, txx, tyy, di, ti: Integer; sr, sg, sb, sat: Single;
    function ToScreen(const clip: TV3): TV3;
    begin Result:=V3((clip.x*0.5+0.5)*FSW, (1-(clip.y*0.5+0.5))*FSH, clip.z); end;
    { shade + rasterize one geometry under a world transform (Mesh & InstancedMesh) }
    function ToScreen4(const c: TV4C): TV3;
    var iw: Single;
    begin
      if Abs(c.w)<1e-9 then iw:=1e9 else iw:=1/c.w;
      Result:=V3((c.x*iw*0.5+0.5)*FSW, (1-(c.y*iw*0.5+0.5))*FSH, c.z*iw);
    end;
    procedure EmitMesh(g: TBufferGeometry; mat: TMaterial; const world: TMat4);
    var tri, j, kf, nout: Integer; ub, textured: Boolean; bcol: TColor; m: TMat4; lw: TV3;
        wpp, wnn: array[0..2] of TV3; inTri: array[0..2] of TClipV; outPoly: array[0..7] of TClipV;
        geoN, centr: TV3; facing: Single; sa, sb, sc: TV3; va, vb, vc: TClipV;
    begin
      if (g=nil) or (mat=nil) then Exit;
      if mat.Transparent <> passTransparent then Exit;   // this object belongs to the other pass
      FBlend:=mat.Transparent; FBlendA:=mat.Opacity;     // RasterTri reads these
      if GWhite=nil then GWhite:=TColor.Create($ffffff);
      bcol:=mat.Color; ub:=mat is TMeshBasicMaterial; m:=Mat4Multiply(vp, world);
      textured:=(mat.Map<>nil) and (System.Length(g.UV)=System.Length(g.Pos)) and (System.Length(g.UV)>0);
      tri:=0;
      while tri+2<System.Length(g.Pos) do
      begin
        for j:=0 to 2 do
        begin
          wpp[j]:=Mat4TransformPoint(world, g.Pos[tri+j]);
          wnn[j]:=VNorm(Mat4TransformDir(world, g.Normals[tri+j]));
        end;
        { backface cull (opt-in via material.Side; default double = no cull) }
        if mat.Side<>msDouble then
        begin
          geoN:=VCross(VSub(wpp[1],wpp[0]), VSub(wpp[2],wpp[0]));
          centr:=VScale(VAdd(VAdd(wpp[0],wpp[1]),wpp[2]), 1/3);
          facing:=VDot(geoN, VSub(centr, camPos));
          if (mat.Side=msFront) and (facing>0) then begin tri:=tri+3; Continue; end;
          if (mat.Side=msBack)  and (facing<0) then begin tri:=tri+3; Continue; end;
        end;
        { build clip-space verts + payload }
        for j:=0 to 2 do
        begin
          inTri[j].c:=Mat4Mul4(m, g.Pos[tri+j]);
          if textured then
          begin
            lw:=ShadeVertex(wpp[j], wnn[j], GWhite, ub);
            inTri[j].col:=V3(lw.x*bcol.r, lw.y*bcol.g, lw.z*bcol.b);
            inTri[j].uv:=g.UV[tri+j];
          end
          else begin inTri[j].col:=ShadeVertex(wpp[j], wnn[j], bcol, ub); inTri[j].uv:=MkUV(0,0); end;
        end;
        ClipNear(inTri, outPoly, nout);
        { fan-triangulate the clipped polygon }
        for kf:=1 to nout-2 do
        begin
          va:=outPoly[0]; vb:=outPoly[kf]; vc:=outPoly[kf+1];
          sa:=ToScreen4(va.c); sb:=ToScreen4(vb.c); sc:=ToScreen4(vc.c);
          if textured then RasterTriTex(sa,sb,sc, va.uv,vb.uv,vc.uv, va.col,vb.col,vc.col, mat.Map)
          else RasterTri(sa,sb,sc, va.col,vb.col,vc.col);
        end;
        tri:=tri+3;
      end;
    end;
  begin
    if not o.Visible then Exit;
    { thread the parent world matrix down — compute each local once, no O(depth)
      re-walk of the ancestor chain per object }
    localM:=Mat4Compose(o.Position.V, o.Rotation.V, o.Scale.V);
    worldM:=Mat4Multiply(parentW, localM); mvp:=Mat4Multiply(vp, worldM);
    if o is TMesh then
    begin
      mesh:=TMesh(o); g:=mesh.Geometry;
      if g<>nil then
      begin
        g.EnsureBounds;
        bc:=Mat4TransformPoint(worldM, V3(g.BCx,g.BCy,g.BCz)); rr:=g.BR*MaxScaleOf(worldM);
        if SphereInFrustum(bc.x,bc.y,bc.z,rr) then EmitMesh(g, mesh.Material, worldM);
      end;
    end
    else if o is TInstancedMesh then
    begin
      im:=TInstancedMesh(o);
      if im.Geometry<>nil then im.Geometry.EnsureBounds;
      for ii:=0 to im.Count-1 do
      begin
        iw:=Mat4Multiply(worldM, im.Matrices[ii]);
        bc:=Mat4TransformPoint(iw, V3(im.Geometry.BCx,im.Geometry.BCy,im.Geometry.BCz));
        rr:=im.Geometry.BR*MaxScaleOf(iw);
        if SphereInFrustum(bc.x,bc.y,bc.z,rr) then EmitMesh(im.Geometry, im.Material, iw);
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
    end
    else if o is TSprite then
    begin
      { camera-facing billboard: project the centre, size by distance, draw a
        screen-aligned textured quad with per-texel alpha, depth-tested. }
      spr:=TSprite(o); sm:=spr.Material;
      if sm<>nil then
      begin
        wc:=V3(worldM.m[12], worldM.m[13], worldM.m[14]);
        vpos:=Mat4TransformPoint(camera.ViewMatrix, wc); sw:=-vpos.z;
        if sw>0.05 then
        begin
          clip:=Mat4TransformPoint(vp, wc);
          cxf:=(clip.x*0.5+0.5)*FSW; cyf:=(1-(clip.y*0.5+0.5))*FSH; depth:=clip.z;
          pxu:=camera.ProjectionMatrix.m[0]*FSW*0.5/sw;
          pyu:=camera.ProjectionMatrix.m[5]*FSH*0.5/sw;
          hw:=spr.Scale.x*0.5*pxu; hh:=spr.Scale.y*0.5*pyu;
          if hw<0.5 then hw:=0.5; if hh<0.5 then hh:=0.5;
          ix0:=Trunc(cxf-hw); ix1:=Trunc(cxf+hw); iy0:=Trunc(cyf-hh); iy1:=Trunc(cyf+hh);
          stex:=sm.Map;
          for yy:=iy0 to iy1 do
            for xx:=ix0 to ix1 do
            begin
              if (xx<0) or (yy<0) or (xx>=FSW) or (yy>=FSH) then Continue;
              di:=yy*FSW+xx;
              if depth>=FZ[di] then Continue;              // occluded by geometry
              if stex<>nil then
              begin
                uu:=(xx-(cxf-hw))/(2*hw); vv:=(yy-(cyf-hh))/(2*hh);
                txx:=Trunc(uu*stex.Width); tyy:=Trunc(vv*stex.Height);
                if (txx<0) or (tyy<0) or (txx>=stex.Width) or (tyy>=stex.Height) then Continue;
                ti:=(tyy*stex.Width+txx)*4;
                sat:=stex.Data[ti+3]/255;
                if sat<=0.003 then Continue;
                sr:=stex.Data[ti]*sm.Color.r; sg:=stex.Data[ti+1]*sm.Color.g; sb:=stex.Data[ti+2]*sm.Color.b;
              end
              else begin sat:=1; sr:=sm.Color.r*255; sg:=sm.Color.g*255; sb:=sm.Color.b*255; end;
              FWK[di*4+0]:=ClampB((sr*sat + FWK[di*4+0]*(1-sat))/255);
              FWK[di*4+1]:=ClampB((sg*sat + FWK[di*4+1]*(1-sat))/255);
              FWK[di*4+2]:=ClampB((sb*sat + FWK[di*4+2]*(1-sat))/255);
              FWK[di*4+3]:=255;
              if sat>0.5 then FZ[di]:=depth;
            end;
        end;
      end;
    end;
    for k:=0 to o.Children.Count-1 do RenderObject(TObject3D(o.Children[k]), worldM);
  end;

begin
  bg:=scene.Background;
  for i:=0 to FSW*FSH-1 do
  begin
    FWK[i*4+0]:=ClampB(bg.r); FWK[i*4+1]:=ClampB(bg.g);
    FWK[i*4+2]:=ClampB(bg.b); FWK[i*4+3]:=255; FZ[i]:=1e30;
  end;
  vp:=Mat4Multiply(camera.ProjectionMatrix, camera.ViewMatrix);
  { frustum planes from vp (column-major m[col*4+row]) — Gribb–Hartmann }
  SetP(0, vp.m[3]+vp.m[0], vp.m[7]+vp.m[4], vp.m[11]+vp.m[8],  vp.m[15]+vp.m[12]);  // left
  SetP(1, vp.m[3]-vp.m[0], vp.m[7]-vp.m[4], vp.m[11]-vp.m[8],  vp.m[15]-vp.m[12]);  // right
  SetP(2, vp.m[3]+vp.m[1], vp.m[7]+vp.m[5], vp.m[11]+vp.m[9],  vp.m[15]+vp.m[13]);  // bottom
  SetP(3, vp.m[3]-vp.m[1], vp.m[7]-vp.m[5], vp.m[11]-vp.m[9],  vp.m[15]-vp.m[13]);  // top
  SetP(4, vp.m[3]+vp.m[2], vp.m[7]+vp.m[6], vp.m[11]+vp.m[10], vp.m[15]+vp.m[14]);  // near
  SetP(5, vp.m[3]-vp.m[2], vp.m[7]-vp.m[6], vp.m[11]-vp.m[10], vp.m[15]-vp.m[14]);  // far
  camPos:=camera.Position.V;
  ambient:=V3(0,0,0); SetLength(dirs,0); SetLength(dcols,0);
  SetLength(plpos,0); SetLength(plcol,0); SetLength(plrange,0);
  CollectLights(scene);
  FBlend:=False;
  passTransparent:=False; RenderObject(scene, Mat4Identity);   // opaque pass (writes depth)
  passTransparent:=True;  RenderObject(scene, Mat4Identity);   // transparent pass (blends, depth-tested)
  FBlend:=False;
  Downsample;                                    // resolve supersampled → Pixels
  if EdgeAA and (FSS<=1) then FXAA;              // cheap post-process edge AA (three.js FXAA)
end;

procedure TWebGLRenderer.FillRectPx(x, y, w, h: Integer; r, g, b: Byte; a: Single);
var px, py, idx: Integer;
begin
  for py:=y to y+h-1 do
    for px:=x to x+w-1 do
    begin
      if (px<0) or (py<0) or (px>=FW) or (py>=FH) then Continue;
      idx:=(py*FW+px)*4;
      Pixels[idx+0]:=ClampB((r*a + Pixels[idx+0]*(1-a))/255);
      Pixels[idx+1]:=ClampB((g*a + Pixels[idx+1]*(1-a))/255);
      Pixels[idx+2]:=ClampB((b*a + Pixels[idx+2]*(1-a))/255);
      Pixels[idx+3]:=255;
    end;
end;

procedure TWebGLRenderer.StrokeRectPx(x, y, w, h, t: Integer; r, g, b: Byte; a: Single);
begin
  FillRectPx(x, y, w, t, r,g,b,a); FillRectPx(x, y+h-t, w, t, r,g,b,a);
  FillRectPx(x, y, t, h, r,g,b,a); FillRectPx(x+w-t, y, t, h, r,g,b,a);
end;

procedure TWebGLRenderer.DrawTextPx(x, y: Integer; const s: string; scale: Integer; r, g, b: Byte);
var i, gi, rr, cc, sx, sy, cx, px, py, idx: Integer; ch: Char; rowstr: string;
begin
  cx:=x;
  for i:=1 to System.Length(s) do
  begin
    ch:=UpCase(s[i]); gi:=GlyphIndex(ch);
    if gi>=0 then
      for rr:=0 to 6 do
      begin
        rowstr:=GLYPHS[gi].rows[rr];
        for cc:=0 to 4 do
          if rowstr[cc+1]='1' then
            for sy:=0 to scale-1 do for sx:=0 to scale-1 do
            begin
              px:=cx+cc*scale+sx; py:=y+rr*scale+sy;
              if (px<0) or (py<0) or (px>=FW) or (py>=FH) then Continue;
              idx:=(py*FW+px)*4; Pixels[idx]:=r; Pixels[idx+1]:=g; Pixels[idx+2]:=b; Pixels[idx+3]:=255;
            end;
      end;
    cx:=cx+6*scale;
  end;
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
