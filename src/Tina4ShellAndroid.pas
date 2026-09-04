unit Tina4ShellAndroid;

{ Android shell for the Tina4 native renderer.

  The core layout/paint code talks only to TTina4Canvas; here that contract is
  implemented on top of android.graphics.Canvas via JNI — the same idea as the
  Cocoa shell using AppKit. The Java side (Tina4View.onDraw) hands us a Canvas
  object per frame; we drive it with a single reused Paint plus a Path for
  polygon fills. Android does the text shaping and anti-aliasing, so glyphs and
  edges match a normal Android app.

  Coordinates are CSS pixels top-left (Android's native origin), colours are
  $AARRGGBB which is exactly android.graphics.Color's packed int. }

{$mode delphi}{$H+}

interface

uses
  jni, Tina4RenderBackend;

type
  TAndroidCanvas = class(TTina4Canvas)
  private
    FEnv: PJNIEnv;
    FCanvas: jobject;          // android.graphics.Canvas for the current frame
    FPaint: jobject;           // reused Paint (global ref)
    // cached classes (global refs)
    clsCanvas, clsPaint, clsPath: jclass;
    // Paint.Style + Path.FillType enum values (global refs)
    styleFill, styleStroke, fillWinding, fillEvenOdd: jobject;
    // Canvas methods
    mDrawRect, mDrawLine, mDrawText, mDrawPath, mDrawRoundRect,
    mSave, mRestore, mClipRect: jmethodID;
    // Paint methods
    mPaintInit, mSetColor, mSetStyle, mSetStrokeWidth, mSetAntiAlias,
    mSetTextSize, mMeasureText, mAscent, mDescent, mSetFakeBold,
    mSetSkewX, mSetUnderline, mSetStrike, mSetFillType: jmethodID;
    // Path methods
    mPathInit, mMoveTo, mLineTo, mClose: jmethodID;
    function MID(cls: jclass; const name, sig: string): jmethodID;
    function EnumVal(const clsName, field, sig: string): jobject;
    function JStr(const S: string): jstring;
    procedure ConfigurePaintText(FontSize: Single; Styles: TTina4FontStyles;
      Color: TTina4Color);
  public
    constructor Create(Env: PJNIEnv);
    procedure BeginFrame(Env: PJNIEnv; Canvas: jobject);
    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); override;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); override;
    procedure FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color); override;
    procedure StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); override;
    procedure FillPolygon(const Contours: array of TTina4PointArray;
      Color: TTina4Color; EvenOdd: Boolean = False); override;
    procedure DrawText(X, Y: Single; const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color); override;
    function MeasureText(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles): TTina4TextMetrics; override;
    procedure SetClip(X, Y, W, H: Single); override;
    procedure ClearClip; override;
    procedure SaveState; override;
    procedure RestoreState; override;
  end;

  { Minimal shell: the Java View owns the window/run loop, so most of the
    contract is a no-op here. It exists so app code can hold event callbacks
    and a measuring canvas, exactly like the Cocoa shell. }
  TAndroidShell = class(TTina4Shell)
  private
    FCanvas: TAndroidCanvas;
  public
    constructor Create(ACanvas: TAndroidCanvas);
    procedure Initialize(Width, Height: Integer; const Title: string); override;
    procedure Invalidate; override;
    procedure Run; override;
    procedure Quit; override;
    function GetMeasuringCanvas: TTina4Canvas; override;
  end;

implementation

const
  // android.graphics.Paint.Style.FILL / STROKE ordinals aren't used; we fetch
  // the enum objects by name. Style constants for setStyle are enum objects.
  PAINT_STYLE_SIG = 'Landroid/graphics/Paint$Style;';
  PATH_FILLTYPE_SIG = 'Landroid/graphics/Path$FillType;';

{ ---- JNI helpers ------------------------------------------------------- }

function TAndroidCanvas.MID(cls: jclass; const name, sig: string): jmethodID;
begin
  Result := FEnv^.GetMethodID(FEnv, cls, PAnsiChar(name), PAnsiChar(sig));
end;

function TAndroidCanvas.EnumVal(const clsName, field, sig: string): jobject;
var c: jclass; fid: jfieldID; o: jobject;
begin
  c := FEnv^.FindClass(FEnv, PAnsiChar(clsName));
  fid := FEnv^.GetStaticFieldID(FEnv, c, PAnsiChar(field), PAnsiChar(sig));
  o := FEnv^.GetStaticObjectField(FEnv, c, fid);
  Result := FEnv^.NewGlobalRef(FEnv, o);
end;

function TAndroidCanvas.JStr(const S: string): jstring;
begin
  Result := FEnv^.NewStringUTF(FEnv, PAnsiChar(S));
end;

constructor TAndroidCanvas.Create(Env: PJNIEnv);
var
  lc: jclass;
  paintObj: jobject;
  a: array[0..0] of jvalue;
begin
  inherited Create;
  FEnv := Env;
  // classes (as global refs so they survive across frames)
  lc := FEnv^.FindClass(FEnv, 'android/graphics/Canvas');
  clsCanvas := FEnv^.NewGlobalRef(FEnv, lc);
  lc := FEnv^.FindClass(FEnv, 'android/graphics/Paint');
  clsPaint := FEnv^.NewGlobalRef(FEnv, lc);
  lc := FEnv^.FindClass(FEnv, 'android/graphics/Path');
  clsPath := FEnv^.NewGlobalRef(FEnv, lc);

  // Canvas methods
  mDrawRect := MID(clsCanvas, 'drawRect', '(FFFFLandroid/graphics/Paint;)V');
  mDrawLine := MID(clsCanvas, 'drawLine', '(FFFFLandroid/graphics/Paint;)V');
  mDrawText := MID(clsCanvas, 'drawText', '(Ljava/lang/String;FFLandroid/graphics/Paint;)V');
  mDrawPath := MID(clsCanvas, 'drawPath', '(Landroid/graphics/Path;Landroid/graphics/Paint;)V');
  mDrawRoundRect := MID(clsCanvas, 'drawRoundRect', '(FFFFFFLandroid/graphics/Paint;)V');
  mSave := MID(clsCanvas, 'save', '()I');
  mRestore := MID(clsCanvas, 'restore', '()V');
  mClipRect := MID(clsCanvas, 'clipRect', '(FFFF)Z');

  // Paint
  mPaintInit := MID(clsPaint, '<init>', '()V');
  mSetColor := MID(clsPaint, 'setColor', '(I)V');
  mSetStyle := MID(clsPaint, 'setStyle', '(' + PAINT_STYLE_SIG + ')V');
  mSetStrokeWidth := MID(clsPaint, 'setStrokeWidth', '(F)V');
  mSetAntiAlias := MID(clsPaint, 'setAntiAlias', '(Z)V');
  mSetTextSize := MID(clsPaint, 'setTextSize', '(F)V');
  mMeasureText := MID(clsPaint, 'measureText', '(Ljava/lang/String;)F');
  mAscent := MID(clsPaint, 'ascent', '()F');
  mDescent := MID(clsPaint, 'descent', '()F');
  mSetFakeBold := MID(clsPaint, 'setFakeBoldText', '(Z)V');
  mSetSkewX := MID(clsPaint, 'setTextSkewX', '(F)V');
  mSetUnderline := MID(clsPaint, 'setUnderlineText', '(Z)V');
  mSetStrike := MID(clsPaint, 'setStrikeThruText', '(Z)V');
  mSetFillType := MID(clsPath, 'setFillType', '(' + PATH_FILLTYPE_SIG + ')V');

  // Path
  mPathInit := MID(clsPath, '<init>', '()V');
  mMoveTo := MID(clsPath, 'moveTo', '(FF)V');
  mLineTo := MID(clsPath, 'lineTo', '(FF)V');
  mClose := MID(clsPath, 'close', '()V');

  // enum values
  styleFill := EnumVal('android/graphics/Paint$Style', 'FILL', PAINT_STYLE_SIG);
  styleStroke := EnumVal('android/graphics/Paint$Style', 'STROKE', PAINT_STYLE_SIG);
  fillWinding := EnumVal('android/graphics/Path$FillType', 'WINDING', PATH_FILLTYPE_SIG);
  fillEvenOdd := EnumVal('android/graphics/Path$FillType', 'EVEN_ODD', PATH_FILLTYPE_SIG);

  // a single reused, anti-aliased Paint
  paintObj := FEnv^.NewObject(FEnv, clsPaint, mPaintInit);
  FPaint := FEnv^.NewGlobalRef(FEnv, paintObj);
  a[0].z := 1;
  FEnv^.CallVoidMethodA(FEnv, FPaint, mSetAntiAlias, @a[0]);
end;

procedure TAndroidCanvas.BeginFrame(Env: PJNIEnv; Canvas: jobject);
begin
  FEnv := Env;
  FCanvas := Canvas;
end;

{ ---- paint config ------------------------------------------------------ }

procedure TAndroidCanvas.ConfigurePaintText(FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color);
var a: array[0..0] of jvalue;
begin
  a[0].i := jint(Color); FEnv^.CallVoidMethodA(FEnv, FPaint, mSetColor, @a[0]);
  a[0].l := styleFill;   FEnv^.CallVoidMethodA(FEnv, FPaint, mSetStyle, @a[0]);
  a[0].f := FontSize;    FEnv^.CallVoidMethodA(FEnv, FPaint, mSetTextSize, @a[0]);
  a[0].z := Ord(tfsBold in Styles);
  FEnv^.CallVoidMethodA(FEnv, FPaint, mSetFakeBold, @a[0]);
  if tfsItalic in Styles then a[0].f := -0.25 else a[0].f := 0;
  FEnv^.CallVoidMethodA(FEnv, FPaint, mSetSkewX, @a[0]);
  a[0].z := Ord(tfsUnderline in Styles);
  FEnv^.CallVoidMethodA(FEnv, FPaint, mSetUnderline, @a[0]);
  a[0].z := Ord(tfsStrike in Styles);
  FEnv^.CallVoidMethodA(FEnv, FPaint, mSetStrike, @a[0]);
end;

{ ---- shapes ------------------------------------------------------------ }

procedure TAndroidCanvas.FillRect(X, Y, W, H: Single; Color: TTina4Color);
var a: array[0..4] of jvalue;
begin
  a[0].i := jint(Color); FEnv^.CallVoidMethodA(FEnv, FPaint, mSetColor, @a[0]);
  a[0].l := styleFill;   FEnv^.CallVoidMethodA(FEnv, FPaint, mSetStyle, @a[0]);
  a[0].f := X; a[1].f := Y; a[2].f := X + W; a[3].f := Y + H; a[4].l := FPaint;
  FEnv^.CallVoidMethodA(FEnv, FCanvas, mDrawRect, @a[0]);
end;

procedure TAndroidCanvas.StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color);
var a: array[0..4] of jvalue;
begin
  a[0].i := jint(Color);  FEnv^.CallVoidMethodA(FEnv, FPaint, mSetColor, @a[0]);
  a[0].l := styleStroke;  FEnv^.CallVoidMethodA(FEnv, FPaint, mSetStyle, @a[0]);
  a[0].f := Thickness;    FEnv^.CallVoidMethodA(FEnv, FPaint, mSetStrokeWidth, @a[0]);
  a[0].f := X + Thickness / 2; a[1].f := Y + Thickness / 2;
  a[2].f := X + W - Thickness / 2; a[3].f := Y + H - Thickness / 2; a[4].l := FPaint;
  FEnv^.CallVoidMethodA(FEnv, FCanvas, mDrawRect, @a[0]);
end;

procedure TAndroidCanvas.FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color);
var a: array[0..6] of jvalue;
begin
  a[0].i := jint(Color); FEnv^.CallVoidMethodA(FEnv, FPaint, mSetColor, @a[0]);
  a[0].l := styleFill;   FEnv^.CallVoidMethodA(FEnv, FPaint, mSetStyle, @a[0]);
  a[0].f := X; a[1].f := Y; a[2].f := X + W; a[3].f := Y + H;
  a[4].f := Radius; a[5].f := Radius; a[6].l := FPaint;
  FEnv^.CallVoidMethodA(FEnv, FCanvas, mDrawRoundRect, @a[0]);
end;

procedure TAndroidCanvas.StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color);
var a: array[0..6] of jvalue;
begin
  a[0].i := jint(Color); FEnv^.CallVoidMethodA(FEnv, FPaint, mSetColor, @a[0]);
  a[0].l := styleStroke; FEnv^.CallVoidMethodA(FEnv, FPaint, mSetStyle, @a[0]);
  a[0].f := Thickness;   FEnv^.CallVoidMethodA(FEnv, FPaint, mSetStrokeWidth, @a[0]);
  a[0].f := X + Thickness / 2; a[1].f := Y + Thickness / 2;
  a[2].f := X + W - Thickness / 2; a[3].f := Y + H - Thickness / 2;
  a[4].f := Radius; a[5].f := Radius; a[6].l := FPaint;
  FEnv^.CallVoidMethodA(FEnv, FCanvas, mDrawRoundRect, @a[0]);
end;

procedure TAndroidCanvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color);
var a: array[0..4] of jvalue;
begin
  a[0].i := jint(Color); FEnv^.CallVoidMethodA(FEnv, FPaint, mSetColor, @a[0]);
  a[0].l := styleStroke; FEnv^.CallVoidMethodA(FEnv, FPaint, mSetStyle, @a[0]);
  a[0].f := Thickness;   FEnv^.CallVoidMethodA(FEnv, FPaint, mSetStrokeWidth, @a[0]);
  a[0].f := X1; a[1].f := Y1; a[2].f := X2; a[3].f := Y2; a[4].l := FPaint;
  FEnv^.CallVoidMethodA(FEnv, FCanvas, mDrawLine, @a[0]);
end;

procedure TAndroidCanvas.FillPolygon(const Contours: array of TTina4PointArray;
  Color: TTina4Color; EvenOdd: Boolean);
var
  pathObj: jobject;
  a: array[0..1] of jvalue;
  i, j: Integer;
begin
  pathObj := FEnv^.NewObject(FEnv, clsPath, mPathInit);
  if EvenOdd then a[0].l := fillEvenOdd else a[0].l := fillWinding;
  FEnv^.CallVoidMethodA(FEnv, pathObj, mSetFillType, @a[0]);
  for i := 0 to High(Contours) do
  begin
    if Length(Contours[i]) < 2 then Continue;
    a[0].f := Contours[i][0].X; a[1].f := Contours[i][0].Y;
    FEnv^.CallVoidMethodA(FEnv, pathObj, mMoveTo, @a[0]);
    for j := 1 to High(Contours[i]) do
    begin
      a[0].f := Contours[i][j].X; a[1].f := Contours[i][j].Y;
      FEnv^.CallVoidMethodA(FEnv, pathObj, mLineTo, @a[0]);
    end;
    FEnv^.CallVoidMethodA(FEnv, pathObj, mClose, nil);
  end;
  a[0].i := jint(Color); FEnv^.CallVoidMethodA(FEnv, FPaint, mSetColor, @a[0]);
  a[0].l := styleFill;   FEnv^.CallVoidMethodA(FEnv, FPaint, mSetStyle, @a[0]);
  a[0].l := pathObj; a[1].l := FPaint;
  FEnv^.CallVoidMethodA(FEnv, FCanvas, mDrawPath, @a[0]);
  FEnv^.DeleteLocalRef(FEnv, pathObj);
end;

{ ---- text -------------------------------------------------------------- }

procedure TAndroidCanvas.DrawText(X, Y: Single; const Text: string; FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color);
var
  a: array[0..3] of jvalue;
  s: jstring;
  ascent: jfloat;
begin
  if Text = '' then Exit;
  ConfigurePaintText(FontSize, Styles, Color);
  ascent := FEnv^.CallFloatMethodA(FEnv, FPaint, mAscent, nil);  // negative
  s := JStr(Text);
  a[0].l := s; a[1].f := X; a[2].f := Y - ascent; a[3].l := FPaint;  // Y=top → baseline
  FEnv^.CallVoidMethodA(FEnv, FCanvas, mDrawText, @a[0]);
  FEnv^.DeleteLocalRef(FEnv, s);
end;

function TAndroidCanvas.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
var
  a: array[0..0] of jvalue;
  s: jstring;
  asc, desc: jfloat;
begin
  ConfigurePaintText(FontSize, Styles, $FF000000);
  if Text = '' then s := JStr(' ') else s := JStr(Text);
  a[0].l := s;
  if Text = '' then Result.Width := 0
  else Result.Width := FEnv^.CallFloatMethodA(FEnv, FPaint, mMeasureText, @a[0]);
  FEnv^.DeleteLocalRef(FEnv, s);
  asc := FEnv^.CallFloatMethodA(FEnv, FPaint, mAscent, nil);    // negative
  desc := FEnv^.CallFloatMethodA(FEnv, FPaint, mDescent, nil);  // positive
  Result.Ascent := -asc;
  Result.Descent := desc;
  Result.LineHeight := desc - asc;
end;

{ ---- clip / state ------------------------------------------------------ }

procedure TAndroidCanvas.SetClip(X, Y, W, H: Single);
var a: array[0..3] of jvalue;
begin
  FEnv^.CallIntMethodA(FEnv, FCanvas, mSave, nil);
  a[0].f := X; a[1].f := Y; a[2].f := X + W; a[3].f := Y + H;
  FEnv^.CallBooleanMethodA(FEnv, FCanvas, mClipRect, @a[0]);
end;

procedure TAndroidCanvas.ClearClip;
begin
  FEnv^.CallVoidMethodA(FEnv, FCanvas, mRestore, nil);
end;

procedure TAndroidCanvas.SaveState;
begin
  FEnv^.CallIntMethodA(FEnv, FCanvas, mSave, nil);
end;

procedure TAndroidCanvas.RestoreState;
begin
  FEnv^.CallVoidMethodA(FEnv, FCanvas, mRestore, nil);
end;

{ ---- shell ------------------------------------------------------------- }

constructor TAndroidShell.Create(ACanvas: TAndroidCanvas);
begin
  inherited Create;
  FCanvas := ACanvas;
end;

procedure TAndroidShell.Initialize(Width, Height: Integer; const Title: string);
begin
  // the Java Activity/View owns the window
end;

procedure TAndroidShell.Invalidate;
begin
  // Java side calls View.invalidate() after handling an event
end;

procedure TAndroidShell.Run;
begin
  // no native run loop; Android drives onDraw
end;

procedure TAndroidShell.Quit;
begin
end;

function TAndroidShell.GetMeasuringCanvas: TTina4Canvas;
begin
  Result := FCanvas;
end;

end.
