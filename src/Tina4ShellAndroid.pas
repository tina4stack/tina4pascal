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
  Classes, jni, Tina4RenderBackend;

{ Write a line to Android logcat (tag "tina4"). Handy for the on-device
  debug loop; cheap enough to leave in. }
procedure AndroidLog(const Msg: string);

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
    mSave, mRestore, mClipRect, mScale: jmethodID;
    // Paint methods
    mPaintInit, mSetColor, mSetStyle, mSetStrokeWidth, mSetAntiAlias,
    mSetTextSize, mMeasureText, mAscent, mDescent, mSetFakeBold,
    mSetSkewX, mSetUnderline, mSetStrike, mSetFillType: jmethodID;
    // Typeface / font-family
    clsTypeface: jclass;
    mSetTypeface, mTypefaceFromFile: jmethodID;
    tfSerif, tfMono, tfSans: jobject;        // static generic typefaces (global refs)
    FRegFonts: TStringList;                  // @font-face: family(lower) → Typeface global ref
    // Path methods
    mPathInit, mMoveTo, mLineTo, mClose: jmethodID;
    // image decode/draw
    clsBmpFactory, clsBitmap, clsRectF: jclass;
    mDecodeFile: jmethodID;                 // BitmapFactory.decodeFile (static)
    mBmpWidth, mBmpHeight: jmethodID;       // Bitmap.getWidth/getHeight
    mRectFInit, mDrawBitmap: jmethodID;
    clsImageLoader: jclass;                 // com.tina4.pascal.ImageLoader
    mImgCached: jmethodID;                  // ImageLoader.cached(url) → local path/""
    FImgSrcs: TStringList;                   // src → index into FImgs
    FImgs: array of record Bmp: jobject; W, H: Single; end;
    procedure EnsureImageMethods;
    function MID(cls: jclass; const name, sig: string): jmethodID;
    function EnumVal(const clsName, field, sig: string): jobject;
    function JStr(const S: string): jstring;
    function JResultStr(S: jobject): string;
    function TypefaceFor(const Family: string): jobject;
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
    procedure Scale(SX, SY: Single); override;
    function LoadImage(const Src: string): Integer; override;
    function ImageSize(Handle: Integer; out W, H: Single): Boolean; override;
    procedure DrawImage(Handle: Integer; X, Y, W, H: Single); override;
    function RegisterFont(const Family, Src: string): Boolean; override;
    destructor Destroy; override;
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

uses SysUtils;

function __android_log_write(prio: Integer; tag, text: PAnsiChar): Integer;
  cdecl; external 'log';

procedure AndroidLog(const Msg: string);
begin
  __android_log_write(4 { INFO }, 'tina4', PAnsiChar(Msg));
end;

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

{ Read a Java String (jstring) into a Pascal string. }
function TAndroidCanvas.JResultStr(S: jobject): string;
var p: PAnsiChar;
begin
  Result := '';
  if S = nil then Exit;
  p := FEnv^.GetStringUTFChars(FEnv, S, nil);
  try Result := string(p);
  finally FEnv^.ReleaseStringUTFChars(FEnv, S, p); end;
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
  mScale := MID(clsCanvas, 'scale', '(FF)V');

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

  // Typeface — for font-family (generic families + @font-face registered fonts)
  lc := FEnv^.FindClass(FEnv, 'android/graphics/Typeface');
  clsTypeface := FEnv^.NewGlobalRef(FEnv, lc);
  mSetTypeface := MID(clsPaint, 'setTypeface',
    '(Landroid/graphics/Typeface;)Landroid/graphics/Typeface;');
  mTypefaceFromFile := FEnv^.GetStaticMethodID(FEnv, clsTypeface, 'createFromFile',
    '(Ljava/lang/String;)Landroid/graphics/Typeface;');
  tfSerif := FEnv^.NewGlobalRef(FEnv, FEnv^.GetStaticObjectField(FEnv, clsTypeface,
    FEnv^.GetStaticFieldID(FEnv, clsTypeface, 'SERIF', 'Landroid/graphics/Typeface;')));
  tfMono := FEnv^.NewGlobalRef(FEnv, FEnv^.GetStaticObjectField(FEnv, clsTypeface,
    FEnv^.GetStaticFieldID(FEnv, clsTypeface, 'MONOSPACE', 'Landroid/graphics/Typeface;')));
  tfSans := FEnv^.NewGlobalRef(FEnv, FEnv^.GetStaticObjectField(FEnv, clsTypeface,
    FEnv^.GetStaticFieldID(FEnv, clsTypeface, 'SANS_SERIF', 'Landroid/graphics/Typeface;')));
  FRegFonts := TStringList.Create;
  FRegFonts.CaseSensitive := False;
  FRegFonts.Sorted := True;   // enables Find()

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

{ Resolve the CSS font-family stack to an android.graphics.Typeface (or nil for
  the default). Registered @font-face faces win; then serif/monospace/sans-serif
  generics; a named face falls through to the default. }
function TAndroidCanvas.TypefaceFor(const Family: string): jobject;
var cand: string; parts: TStringArray; k, idx: Integer;
begin
  Result := nil;
  if Trim(Family) = '' then Exit;
  parts := Family.Split([',']);
  for k := 0 to High(parts) do
  begin
    cand := Trim(parts[k]).DeQuotedString('"').DeQuotedString('''');
    cand := Trim(cand);
    if cand = '' then Continue;
    if (FRegFonts <> nil) and FRegFonts.Find(cand, idx) then
      Exit(FRegFonts.Objects[idx]);                       // @font-face registered
    if SameText(cand, 'serif') then Exit(tfSerif)
    else if SameText(cand, 'monospace') then Exit(tfMono)
    else if SameText(cand, 'sans-serif') or SameText(cand, 'system-ui')
         or SameText(cand, '-apple-system') then Exit(tfSans);
    // a named face we don't have registered — keep looking down the stack
  end;
end;

procedure TAndroidCanvas.ConfigurePaintText(FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color);
var a: array[0..0] of jvalue; tf: jobject;
begin
  tf := TypefaceFor(FontFamily);
  a[0].l := tf;   // nil => default typeface
  FEnv^.CallObjectMethodA(FEnv, FPaint, mSetTypeface, @a[0]);
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

procedure TAndroidCanvas.Scale(SX, SY: Single);
var a: array[0..1] of jvalue;
begin
  a[0].f := SX; a[1].f := SY;
  FEnv^.CallVoidMethodA(FEnv, FCanvas, mScale, @a[0]);
end;

{ ---- images ------------------------------------------------------------ }

{ Resolve the JNI handles for BitmapFactory/Bitmap/RectF the first time an
  image is actually used (keeps the constructor lean and avoids the cost when
  a document has no images). }
procedure TAndroidCanvas.EnsureImageMethods;
var lc: jclass;
begin
  if clsBmpFactory <> nil then Exit;
  lc := FEnv^.FindClass(FEnv, 'android/graphics/BitmapFactory');
  clsBmpFactory := FEnv^.NewGlobalRef(FEnv, lc);
  lc := FEnv^.FindClass(FEnv, 'android/graphics/Bitmap');
  clsBitmap := FEnv^.NewGlobalRef(FEnv, lc);
  lc := FEnv^.FindClass(FEnv, 'android/graphics/RectF');
  clsRectF := FEnv^.NewGlobalRef(FEnv, lc);
  mDecodeFile := FEnv^.GetStaticMethodID(FEnv, clsBmpFactory, 'decodeFile',
    '(Ljava/lang/String;)Landroid/graphics/Bitmap;');
  mBmpWidth  := MID(clsBitmap, 'getWidth',  '()I');
  mBmpHeight := MID(clsBitmap, 'getHeight', '()I');
  mRectFInit := MID(clsRectF, '<init>', '(FFFF)V');
  mDrawBitmap := MID(clsCanvas, 'drawBitmap',
    '(Landroid/graphics/Bitmap;Landroid/graphics/Rect;Landroid/graphics/RectF;Landroid/graphics/Paint;)V');
  lc := FEnv^.FindClass(FEnv, 'com/tina4/pascal/ImageLoader');
  if lc <> nil then
  begin
    clsImageLoader := FEnv^.NewGlobalRef(FEnv, lc);
    mImgCached := FEnv^.GetStaticMethodID(FEnv, clsImageLoader, 'cached',
      '(Ljava/lang/String;)Ljava/lang/String;');
  end;
  FImgSrcs := TStringList.Create;
end;

function TAndroidCanvas.LoadImage(const Src: string): Integer;
var
  a: array[0..0] of jvalue;
  s, js, bmp, gbmp: jobject;
  n: Integer;
  lower, local: string;
begin
  Result := -1;
  if Src = '' then Exit;
  EnsureImageMethods;
  n := FImgSrcs.IndexOf(Src);
  if n >= 0 then Exit(PtrInt(FImgSrcs.Objects[n]));   // decoded, in-memory cache
  // http(s): ImageLoader.cached returns the local cache path if downloaded, or
  // "" while it fetches async on a worker thread (native TLS). We decode the
  // cached FILE; a not-yet-ready image returns -1 (not cached as a failure) and
  // reappears after nativeImageReady triggers a relayout.
  lower := LowerCase(Src);
  if (Pos('http://', lower) = 1) or (Pos('https://', lower) = 1) then
  begin
    if clsImageLoader = nil then Exit;
    s := JStr(Src);
    a[0].l := s;
    js := FEnv^.CallStaticObjectMethodA(FEnv, clsImageLoader, mImgCached, @a[0]);
    FEnv^.DeleteLocalRef(FEnv, s);
    local := JResultStr(js);
    if js <> nil then FEnv^.DeleteLocalRef(FEnv, js);
    if local = '' then Exit;                          // still downloading
  end
  else
    local := Src;                                     // local file path
  s := JStr(local);
  a[0].l := s;
  bmp := FEnv^.CallStaticObjectMethodA(FEnv, clsBmpFactory, mDecodeFile, @a[0]);
  FEnv^.DeleteLocalRef(FEnv, s);
  if bmp = nil then Exit;
  gbmp := FEnv^.NewGlobalRef(FEnv, bmp);
  FEnv^.DeleteLocalRef(FEnv, bmp);
  n := Length(FImgs);
  SetLength(FImgs, n + 1);
  FImgs[n].Bmp := gbmp;
  FImgs[n].W := FEnv^.CallIntMethodA(FEnv, gbmp, mBmpWidth, nil);
  FImgs[n].H := FEnv^.CallIntMethodA(FEnv, gbmp, mBmpHeight, nil);
  FImgSrcs.AddObject(Src, TObject(PtrInt(n)));
  Result := n;
end;

function TAndroidCanvas.ImageSize(Handle: Integer; out W, H: Single): Boolean;
begin
  Result := (Handle >= 0) and (Handle < Length(FImgs));
  if Result then begin W := FImgs[Handle].W; H := FImgs[Handle].H; end
  else begin W := 0; H := 0; end;
end;

procedure TAndroidCanvas.DrawImage(Handle: Integer; X, Y, W, H: Single);
var a: array[0..3] of jvalue; dst: jobject;
begin
  if (Handle < 0) or (Handle >= Length(FImgs)) then Exit;
  a[0].f := X; a[1].f := Y; a[2].f := X + W; a[3].f := Y + H;
  dst := FEnv^.NewObjectA(FEnv, clsRectF, mRectFInit, @a[0]);
  a[0].l := FImgs[Handle].Bmp; a[1].l := nil; a[2].l := dst; a[3].l := FPaint;
  FEnv^.CallVoidMethodA(FEnv, FCanvas, mDrawBitmap, @a[0]);
  FEnv^.DeleteLocalRef(FEnv, dst);
end;

function TAndroidCanvas.RegisterFont(const Family, Src: string): Boolean;
var a: array[0..0] of jvalue; s, js, tf, gtf: jobject; idx: Integer;
    local, lower: string;
begin
  Result := False;
  if (Trim(Family) = '') or (Trim(Src) = '') or (clsTypeface = nil)
     or (FRegFonts = nil) then Exit;
  // http(s): reuse the async ImageLoader (native-TLS worker + disk cache). It
  // returns the local path once fetched, or "" while downloading — in which
  // case we bail and the post-fetch relayout re-runs this with the file present.
  lower := LowerCase(Src);
  if (Pos('http://', lower) = 1) or (Pos('https://', lower) = 1) then
  begin
    EnsureImageMethods;
    if clsImageLoader = nil then Exit;
    s := JStr(Src);
    a[0].l := s;
    js := FEnv^.CallStaticObjectMethodA(FEnv, clsImageLoader, mImgCached, @a[0]);
    FEnv^.DeleteLocalRef(FEnv, s);
    local := JResultStr(js);
    if js <> nil then FEnv^.DeleteLocalRef(FEnv, js);
    if local = '' then Exit;                  // still downloading — retry later
  end
  else
    local := Src;                             // local file path
  s := JStr(local);
  a[0].l := s;
  tf := FEnv^.CallStaticObjectMethodA(FEnv, clsTypeface, mTypefaceFromFile, @a[0]);
  FEnv^.DeleteLocalRef(FEnv, s);
  if tf = nil then Exit;                    // unreadable / bad font file
  gtf := FEnv^.NewGlobalRef(FEnv, tf);
  FEnv^.DeleteLocalRef(FEnv, tf);
  if FRegFonts.Find(Family, idx) then FRegFonts.Objects[idx] := gtf
  else FRegFonts.AddObject(Family, gtf);
  Result := True;
end;

destructor TAndroidCanvas.Destroy;
var i: Integer;
begin
  for i := 0 to High(FImgs) do
    if FImgs[i].Bmp <> nil then FEnv^.DeleteGlobalRef(FEnv, FImgs[i].Bmp);
  FImgSrcs.Free;
  if FRegFonts <> nil then
  begin
    for i := 0 to FRegFonts.Count - 1 do
      if FRegFonts.Objects[i] <> nil then
        FEnv^.DeleteGlobalRef(FEnv, jobject(FRegFonts.Objects[i]));
    FRegFonts.Free;
  end;
  inherited Destroy;
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
