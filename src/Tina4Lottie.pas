unit Tina4Lottie;

{ A pure-Pascal Lottie player — Bodymovin JSON animation, no Skia, no JS.

  Parses a Lottie animation (fpjson) and renders any frame onto a Tina4Canvas2D,
  so a <lottie> is drawn by the SAME portable canvas as everything else and
  animates off the shared ticker. Supported (the common shape-animation subset):
  shape layers, groups (gr), bezier paths (sh) with keyframe MORPHING, fills (fl)
  with the winding rule (nonzero/even-odd holes), strokes (st), group + layer
  transforms (position/rotation/scale/anchor/opacity), layer parenting (a null
  parent cascades its transform, not its opacity), correct top-first paint order,
  and keyframed properties with cubic-bezier temporal easing. Not yet: gradients,
  text, images, masks/mattes, precomps, trim paths. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Math, Classes, fpjson, jsonparser, Tina4RenderBackend, Tina4Canvas2D;

type
  TTina4Lottie = class
  private
    FRoot: TJSONObject;
    FLayers: TJSONArray;
    FW, FH, FFps, FIp, FOp: Single;
    function LayerByInd(ind: Integer): TJSONObject;
    procedure ApplyAncestors(ctx: TTina4Canvas2D; layer: TJSONObject; frame: Single;
      var alpha: Single);
    procedure RenderLayer(ctx: TTina4Canvas2D; layer: TJSONObject; frame: Single);
    procedure RenderShapes(ctx: TTina4Canvas2D; items: TJSONArray; frame: Single;
      parentAlpha: Single);
    procedure BuildPath(ctx: TTina4Canvas2D; shp: TJSONObject; frame: Single);
    procedure ApplyTransform(ctx: TTina4Canvas2D; tr: TJSONObject; frame: Single;
      var alpha: Single);
  public
    destructor Destroy; override;
    function LoadFromString(const JSON: string): Boolean;
    procedure Render(ctx: TTina4Canvas2D; frame: Single);
    property Width: Single read FW;
    property Height: Single read FH;
    property FrameRate: Single read FFps;
    property InPoint: Single read FIp;
    property OutPoint: Single read FOp;
  end;

{ Parse-once cache keyed by the JSON text (inline <lottie> content), so the paint
  path doesn't re-parse every frame. Returns nil on parse failure. }
function GetLottieFor(const JSON: string): TTina4Lottie;

implementation

var
  GCacheKeys: array of string;
  GCacheObjs: array of TTina4Lottie;

function GetLottieFor(const JSON: string): TTina4Lottie;
var i, n: Integer; lot: TTina4Lottie;
begin
  for i := 0 to High(GCacheKeys) do
    if GCacheKeys[i] = JSON then Exit(GCacheObjs[i]);
  lot := TTina4Lottie.Create;
  if not lot.LoadFromString(JSON) then begin lot.Free; Exit(nil); end;
  n := Length(GCacheKeys); SetLength(GCacheKeys, n + 1); SetLength(GCacheObjs, n + 1);
  GCacheKeys[n] := JSON; GCacheObjs[n] := lot;
  Result := lot;
end;

{ ---- small JSON helpers ------------------------------------------------ }

function JNum(N: TJSONData; Def: Single = 0): Single;
begin
  if N = nil then Exit(Def);
  case N.JSONType of
    jtNumber:  Result := N.AsFloat;
    jtBoolean: if N.AsBoolean then Result := 1 else Result := 0;  // bodymovin 'c' is a JSON bool
  else
    Result := Def;
  end;
end;

function JObj(P: TJSONData; const Key: string): TJSONObject;
var d: TJSONData;
begin
  Result := nil;
  if (P <> nil) and (P is TJSONObject) then
  begin d := TJSONObject(P).Find(Key); if d is TJSONObject then Result := TJSONObject(d); end;
end;

function JArr(P: TJSONData; const Key: string): TJSONArray;
var d: TJSONData;
begin
  Result := nil;
  if (P <> nil) and (P is TJSONObject) then
  begin d := TJSONObject(P).Find(Key); if d is TJSONArray then Result := TJSONArray(d); end;
end;

{ cubic-bezier easing y for x=t, control points (x1,y1),(x2,y2) — CSS-style }
function BezEase(t, x1, y1, x2, y2: Single): Single;
var u, x, lo, hi, tt: Single; i: Integer;
begin
  if t <= 0 then Exit(0);
  if t >= 1 then Exit(1);
  lo := 0; hi := 1; tt := t;
  for i := 0 to 18 do          // binary search the bezier param whose X = t
  begin
    u := 1 - tt;
    x := 3 * u * u * tt * x1 + 3 * u * tt * tt * x2 + tt * tt * tt;
    if x < t then lo := tt else hi := tt;
    tt := (lo + hi) / 2;
  end;
  u := 1 - tt;
  Result := 3 * u * u * tt * y1 + 3 * u * tt * tt * y2 + tt * tt * tt;
end;

{ read handle.x / handle.y which may be a number or a 1-element array }
function EaseHandle(h: TJSONData; const Axis: string; def: Single): Single;
var d: TJSONData;
begin
  Result := def;
  if not (h is TJSONObject) then Exit;
  d := TJSONObject(h).Find(Axis);
  if d is TJSONArray then
  begin if TJSONArray(d).Count > 0 then Result := JNum(TJSONArray(d)[0], def); end
  else Result := JNum(d, def);
end;

{ Evaluate an animated/static property's Nth component at `frame`. A property is
  static (a=0, k is a number or array) or keyframed (a=1, k is a list of
  keyframes each with t/s/i/o). }
function EvalComp(prop: TJSONData; frame: Single; comp: Integer; def: Single): Single;
var k: TJSONData; kf, kf2: TJSONObject; arr: TJSONArray;
    i: Integer; t0, t1, s0, s1, lt, e, ix, iy, ox, oy: Single;
    sArr, eArr: TJSONArray;

  function CompOf(d: TJSONData; c: Integer; dv: Single): Single;
  begin
    if d = nil then Exit(dv);
    if d is TJSONArray then
    begin
      if c < TJSONArray(d).Count then Result := JNum(TJSONArray(d)[c], dv) else Result := dv;
    end
    else Result := JNum(d, dv);
  end;

begin
  Result := def;
  if not (prop is TJSONObject) then Exit;
  k := TJSONObject(prop).Find('k');
  if k = nil then Exit;
  if JNum(TJSONObject(prop).Find('a'), 0) = 0 then
    Exit(CompOf(k, comp, def));            // static
  if not (k is TJSONArray) then Exit;
  arr := TJSONArray(k);
  if arr.Count = 0 then Exit;
  if frame <= JNum(TJSONObject(arr[0]).Find('t')) then
    Exit(CompOf(TJSONObject(arr[0]).Find('s'), comp, def));
  for i := 0 to arr.Count - 2 do
  begin
    kf := TJSONObject(arr[i]); kf2 := TJSONObject(arr[i + 1]);
    t0 := JNum(kf.Find('t')); t1 := JNum(kf2.Find('t'));
    if (frame >= t0) and (frame < t1) then
    begin
      sArr := nil; eArr := nil;
      if kf.Find('s') is TJSONArray then sArr := TJSONArray(kf.Find('s'));
      if kf.Find('e') is TJSONArray then eArr := TJSONArray(kf.Find('e'))
      else if kf2.Find('s') is TJSONArray then eArr := TJSONArray(kf2.Find('s'));
      s0 := CompOf(sArr, comp, def);
      s1 := CompOf(eArr, comp, s0);
      if t1 <= t0 then Exit(s1);
      lt := (frame - t0) / (t1 - t0);
      // temporal easing: bezier control points from kf.o (out) and kf.i (in)
      ox := EaseHandle(kf.Find('o'), 'x', 0.667);
      oy := EaseHandle(kf.Find('o'), 'y', 0.667);
      ix := EaseHandle(kf.Find('i'), 'x', 0.333);
      iy := EaseHandle(kf.Find('i'), 'y', 0.333);
      e := BezEase(lt, ox, oy, ix, iy);
      Exit(s0 + (s1 - s0) * e);
    end;
  end;
  Exit(CompOf(TJSONObject(arr[arr.Count - 1]).Find('s'), comp, def));
end;

{ ---- TTina4Lottie ----------------------------------------------------- }

destructor TTina4Lottie.Destroy;
begin FRoot.Free; inherited; end;

function TTina4Lottie.LoadFromString(const JSON: string): Boolean;
var d: TJSONData;
begin
  Result := False;
  FreeAndNil(FRoot);
  try d := GetJSON(JSON); except d := nil; end;
  if not (d is TJSONObject) then begin d.Free; Exit; end;
  FRoot := TJSONObject(d);
  FW := JNum(FRoot.Find('w'), 100); FH := JNum(FRoot.Find('h'), 100);
  FFps := JNum(FRoot.Find('fr'), 30);
  FIp := JNum(FRoot.Find('ip'), 0); FOp := JNum(FRoot.Find('op'), 60);
  Result := True;
end;

procedure TTina4Lottie.ApplyTransform(ctx: TTina4Canvas2D; tr: TJSONObject;
  frame: Single; var alpha: Single);
var px, py, ax, ay, sx, sy, r, o: Single;
begin
  if tr = nil then Exit;
  px := EvalComp(tr.Find('p'), frame, 0, 0); py := EvalComp(tr.Find('p'), frame, 1, 0);
  ax := EvalComp(tr.Find('a'), frame, 0, 0); ay := EvalComp(tr.Find('a'), frame, 1, 0);
  sx := EvalComp(tr.Find('s'), frame, 0, 100); sy := EvalComp(tr.Find('s'), frame, 1, 100);
  r  := EvalComp(tr.Find('r'), frame, 0, 0);
  o  := EvalComp(tr.Find('o'), frame, 0, 100);
  ctx.Translate(px, py);
  if r <> 0 then ctx.Rotate(r * Pi / 180);
  if (sx <> 100) or (sy <> 100) then ctx.Scale(sx / 100, sy / 100);
  ctx.Translate(-ax, -ay);
  alpha := alpha * (o / 100);
end;

procedure TTina4Lottie.BuildPath(ctx: TTina4Canvas2D; shp: TJSONObject; frame: Single);
var ksd, kd: TJSONData; p0, p1: TJSONObject;
    v0, i0, o0, v1, i1, o1: TJSONArray; n, j, jn: Integer;
    vx, vy, o1x, o1y, i2x, i2y, nx, ny, mix, lt, t0, t1: Single;
    arr: TJSONArray; i: Integer; closed: Boolean; kf: TJSONObject;

  function VC(a: TJSONArray; idx, comp: Integer): Single;
  begin
    Result := 0;
    if (a <> nil) and (idx < a.Count) and (a[idx] is TJSONArray)
       and (comp < TJSONArray(a[idx]).Count) then
      Result := JNum(TJSONArray(a[idx])[comp]);
  end;
  // morphed component: linear-interpolate matching vertices of the two shapes
  function LV(a, b: TJSONArray; idx, comp: Integer): Single;
  var va, vb: Single;
  begin
    va := VC(a, idx, comp); vb := VC(b, idx, comp);
    Result := va + (vb - va) * mix;
  end;

  function ShapeAt(pk: TJSONData): TJSONObject;
  begin
    Result := nil;
    if (pk is TJSONArray) and (TJSONArray(pk).Count > 0) then
      Result := TJSONObject(TJSONArray(pk)[0]);
  end;

begin
  ksd := shp.Find('ks');
  if not (ksd is TJSONObject) then Exit;
  kd := TJSONObject(ksd).Find('k');
  p0 := nil; p1 := nil; mix := 0;
  if JNum(TJSONObject(ksd).Find('a'), 0) = 0 then
  begin
    if kd is TJSONObject then begin p0 := TJSONObject(kd); p1 := p0; end;
  end
  else if kd is TJSONArray then
  begin
    arr := TJSONArray(kd);
    if arr.Count = 0 then Exit;
    if frame <= JNum(TJSONObject(arr[0]).Find('t')) then
    begin p0 := ShapeAt(TJSONObject(arr[0]).Find('s')); p1 := p0; end
    else
    begin
      for i := 0 to arr.Count - 2 do
      begin
        kf := TJSONObject(arr[i]);
        t0 := JNum(kf.Find('t')); t1 := JNum(TJSONObject(arr[i + 1]).Find('t'));
        if (frame >= t0) and (frame < t1) then
        begin
          p0 := ShapeAt(kf.Find('s'));
          p1 := ShapeAt(TJSONObject(arr[i + 1]).Find('s'));
          if p1 = nil then p1 := p0;
          if t1 > t0 then lt := (frame - t0) / (t1 - t0) else lt := 0;
          mix := BezEase(lt,
            EaseHandle(kf.Find('o'), 'x', 0.667), EaseHandle(kf.Find('o'), 'y', 0.667),
            EaseHandle(kf.Find('i'), 'x', 0.333), EaseHandle(kf.Find('i'), 'y', 0.333));
          Break;
        end;
      end;
      if p0 = nil then
      begin p0 := ShapeAt(TJSONObject(arr[arr.Count - 1]).Find('s')); p1 := p0; end;
    end;
  end;
  if p0 = nil then Exit;
  if p1 = nil then p1 := p0;
  v0 := JArr(p0, 'v'); i0 := JArr(p0, 'i'); o0 := JArr(p0, 'o');
  v1 := JArr(p1, 'v'); i1 := JArr(p1, 'i'); o1 := JArr(p1, 'o');
  if (v0 = nil) or (v0.Count = 0) then Exit;
  n := v0.Count;
  if (v1 <> nil) and (v1.Count < n) then n := v1.Count;   // guard mismatched counts
  closed := JNum(p0.Find('c'), 0) <> 0;
  ctx.MoveTo(LV(v0, v1, 0, 0), LV(v0, v1, 0, 1));
  for j := 0 to n - 1 do
  begin
    jn := (j + 1) mod n;
    if (jn = 0) and not closed then Break;      // open path: stop at the last vertex
    vx := LV(v0, v1, j, 0);  vy := LV(v0, v1, j, 1);
    nx := LV(v0, v1, jn, 0); ny := LV(v0, v1, jn, 1);
    o1x := vx + LV(o0, o1, j, 0);  o1y := vy + LV(o0, o1, j, 1);   // out tangent (relative)
    i2x := nx + LV(i0, i1, jn, 0); i2y := ny + LV(i0, i1, jn, 1);  // in tangent (relative)
    ctx.BezierCurveTo(o1x, o1y, i2x, i2y, nx, ny);
  end;
  if closed then ctx.ClosePath;
end;

procedure TTina4Lottie.RenderShapes(ctx: TTina4Canvas2D; items: TJSONArray;
  frame: Single; parentAlpha: Single);
var i: Integer; it: TJSONObject; ty: string;
    fillCol, strokeCol: TTina4Color; hasFill, hasStroke, fillEvenOdd: Boolean;
    strokeW, a, cr, cg, cb, ca, fo, so: Single; grAlpha: Single;
    trObj: TJSONObject; k: Integer;
begin
  // one paint pass per group: gather fill/stroke, build the path(s), paint.
  // Items are painted top-of-array first (After Effects order), so iterate in
  // REVERSE: the last item paints at the bottom, item 0 ends up on top.
  hasFill := False; hasStroke := False; fillEvenOdd := False; strokeW := 1;
  fillCol := 0; strokeCol := 0; grAlpha := parentAlpha;
  ctx.BeginPath;
  for i := items.Count - 1 downto 0 do
  begin
    if not (items[i] is TJSONObject) then Continue;
    it := TJSONObject(items[i]);
    ty := '';
    if it.Find('ty') <> nil then ty := it.Find('ty').AsString;
    if ty = 'gr' then
    begin
      // nested group: its own transform + items, isolated on the canvas state
      ctx.Save;
      trObj := nil; grAlpha := parentAlpha;
      if JArr(it, 'it') <> nil then
      begin
        // find the group transform (tr) to apply first
        for k := 0 to JArr(it, 'it').Count - 1 do
          if (JArr(it, 'it')[k] is TJSONObject)
             and (TJSONObject(JArr(it, 'it')[k]).Find('ty') <> nil)
             and (TJSONObject(JArr(it, 'it')[k]).Find('ty').AsString = 'tr') then
            trObj := TJSONObject(JArr(it, 'it')[k]);
        ApplyTransform(ctx, trObj, frame, grAlpha);
        RenderShapes(ctx, JArr(it, 'it'), frame, grAlpha);
      end;
      ctx.Restore;
    end
    else if ty = 'sh' then
      BuildPath(ctx, it, frame)
    else if ty = 'fl' then
    begin
      hasFill := True;
      if (it.Find('r') <> nil) and (it.Find('r').JSONType = jtNumber) then
        fillEvenOdd := it.Find('r').AsInteger = 2;   // 1 = nonzero, 2 = even-odd
      cr := EvalComp(it.Find('c'), frame, 0, 0) * 255;
      cg := EvalComp(it.Find('c'), frame, 1, 0) * 255;
      cb := EvalComp(it.Find('c'), frame, 2, 0) * 255;
      ca := EvalComp(it.Find('c'), frame, 3, 1) * 255;
      fo := EvalComp(it.Find('o'), frame, 0, 100) / 100 * parentAlpha;
      fillCol := (Round(Max(0, Min(255, ca * fo))) shl 24)
              or (Round(Max(0, Min(255, cr))) shl 16)
              or (Round(Max(0, Min(255, cg))) shl 8)
              or Round(Max(0, Min(255, cb)));
    end
    else if ty = 'st' then
    begin
      hasStroke := True;
      strokeW := EvalComp(it.Find('w'), frame, 0, 1);
      cr := EvalComp(it.Find('c'), frame, 0, 0) * 255;
      cg := EvalComp(it.Find('c'), frame, 1, 0) * 255;
      cb := EvalComp(it.Find('c'), frame, 2, 0) * 255;
      so := EvalComp(it.Find('o'), frame, 0, 100) / 100 * parentAlpha;
      strokeCol := (Round(Max(0, Min(255, 255 * so))) shl 24)
                or (Round(Max(0, Min(255, cr))) shl 16)
                or (Round(Max(0, Min(255, cg))) shl 8)
                or Round(Max(0, Min(255, cb)));
    end;
  end;
  if hasFill then begin ctx.SetFillColor(fillCol); ctx.Fill(fillEvenOdd); end;
  if hasStroke then
  begin ctx.SetStrokeColor(strokeCol); ctx.SetLineWidth(strokeW); ctx.Stroke; end;
end;

function TTina4Lottie.LayerByInd(ind: Integer): TJSONObject;
var i: Integer;
begin
  Result := nil;
  if FLayers = nil then Exit;
  for i := 0 to FLayers.Count - 1 do
    if (FLayers[i] is TJSONObject)
       and (Round(JNum(TJSONObject(FLayers[i]).Find('ind'), -99999)) = ind) then
      Exit(TJSONObject(FLayers[i]));
end;

{ Apply the transforms of every ancestor (outermost first) so a parented layer
  lands in its parent's coordinate space — a null-layer parent is how the whole
  composition is positioned/scaled. }
procedure TTina4Lottie.ApplyAncestors(ctx: TTina4Canvas2D; layer: TJSONObject;
  frame: Single; var alpha: Single);
var pd: TJSONData; parent: TJSONObject; dummy: Single;
begin
  pd := layer.Find('parent');
  if pd = nil then Exit;
  parent := LayerByInd(Round(JNum(pd, -99999)));
  if parent = nil then Exit;
  ApplyAncestors(ctx, parent, frame, alpha);        // grandparents first
  // a parent cascades its TRANSFORM to children, but NOT its opacity — a null
  // parent with opacity 0 still positions its (visible) children.
  dummy := 1;
  ApplyTransform(ctx, JObj(parent, 'ks'), frame, dummy);
end;

procedure TTina4Lottie.RenderLayer(ctx: TTina4Canvas2D; layer: TJSONObject; frame: Single);
var alpha: Single; shapes: TJSONArray; ip, op: Single;
begin
  if JNum(layer.Find('ty'), -1) <> 4 then Exit;   // shape layers only (for now)
  ip := JNum(layer.Find('ip'), FIp); op := JNum(layer.Find('op'), FOp);
  if (frame < ip) or (frame >= op) then Exit;      // layer not active this frame
  shapes := JArr(layer, 'shapes');
  if shapes = nil then Exit;
  ctx.Save;
  alpha := 1;
  ApplyAncestors(ctx, layer, frame, alpha);        // parent chain (null-layer, etc.)
  ApplyTransform(ctx, JObj(layer, 'ks'), frame, alpha);
  RenderShapes(ctx, shapes, frame, alpha);
  ctx.Restore;
end;

procedure TTina4Lottie.Render(ctx: TTina4Canvas2D; frame: Single);
var layers: TJSONArray; i: Integer;
begin
  if FRoot = nil then Exit;
  layers := JArr(FRoot, 'layers');
  if layers = nil then Exit;
  FLayers := layers;   // for parent lookups
  // Lottie paints last layer first (top of the array is on top)
  for i := layers.Count - 1 downto 0 do
    if layers[i] is TJSONObject then
      RenderLayer(ctx, TJSONObject(layers[i]), frame);
end;

end.
