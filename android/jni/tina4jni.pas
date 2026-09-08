library tina4jni;

{ JNI entry points for the Tina4Pascal Android shell.

  This is a THIN bridge: every entry point forwards to the shared, portable
  interaction engine in Tina4Interact (the same engine every other shell uses).
  The only Android-specific work here is creating the TAndroidCanvas, handing
  it the per-frame android.graphics.Canvas (BeginFrame), and marshalling
  jstring ↔ string. All layout, scrolling, focus, the caret, the <select>
  dropdown and the file/camera routing live in Tina4Interact. }

{$mode delphi}{$H+}

uses
  SysUtils, Math,
  jni,
  Tina4RenderBackend, Tina4ShellAndroid, Tina4Interact,
  Tina4Http, Tina4HttpAndroid,
  ThreePascal, RamModel
  { A project's own units (declared as "appUnits" in tina4.json) are spliced in
    here by the android build. Each registers its named actions in its own
    initialization, so the app's Pascal logic ships in libtina4.so without
    editing this shell. Defaults to empty (app_units.inc below). }
  {$I app_units.inc} ;

var
  GCanvas: TAndroidCanvas = nil;
  GShell: TAndroidShell = nil;
  GAssetBase: string = '';        // filesDir where MainActivity extracted APK assets
  {$IFDEF TINA_PROFILE}GProfT0: QWord;{$ENDIF}

function JToStr(Env: PJNIEnv; S: jstring): string;
var p: PAnsiChar;
begin
  Result := '';
  if S = nil then Exit;
  p := Env^.GetStringUTFChars(Env, S, nil);
  try Result := string(p);
  finally Env^.ReleaseStringUTFChars(Env, S, p); end;
end;

{ cache the JavaVM and install the native (HttpURLConnection) HTTP backend }
function JNI_OnLoad(VM: PJavaVM; Reserved: Pointer): jint; cdecl;
begin
  InstallAndroidHttp(VM);
  Result := JNI_VERSION_1_6;
end;

{ Java Http worker → native: hand a completed response to the pump queue }
procedure Java_com_tina4_pascal_Http_nativeHttpResult(Env: PJNIEnv; This: jobject;
  Id, Status: jint; Body, Error: jstring); cdecl;
begin
  AndroidHttpResult(Id, Status, JToStr(Env, Body), JToStr(Env, Error));
end;

{ Java ImageLoader → native: a remote <img> finished downloading to the cache;
  relayout so LoadImage decodes it (the Java side also invalidates the view). }
procedure Java_com_tina4_pascal_ImageLoader_nativeImageReady(Env: PJNIEnv; This: jobject); cdecl;
begin
  TinaInvalidateLayout;
end;

procedure Java_com_tina4_pascal_Tina4View_nativeSetHtml(Env: PJNIEnv; This: jobject;
  Html: jstring); cdecl;
begin
  TinaSetHtml(JToStr(Env, Html));
end;

function Java_com_tina4_pascal_Tina4View_nativeWantsKeyboard(Env: PJNIEnv;
  This: jobject): jint; cdecl;
begin
  Result := TinaWantsKeyboard;
end;

procedure Java_com_tina4_pascal_Tina4View_nativePaint(Env: PJNIEnv; This: jobject;
  Canvas: jobject; W, H: jint; Density: jfloat); cdecl;
begin
  if GCanvas = nil then
  begin
    GCanvas := TAndroidCanvas.Create(Env);
    GShell := TAndroidShell.Create(GCanvas);
    GCanvas.SetAssetBase(GAssetBase);   // relative <img src> → extracted APK assets
    TinaInit(GCanvas);
  end;
  HttpPump;                    // deliver any completed HTTP responses (main thread)
  GCanvas.BeginFrame(Env, Canvas);
  {$IFDEF TINA_PROFILE}
  GProfT0 := GetTickCount64;
  TinaFrame(W, H, Density);
  AndroidLog(Format('nativePaint %d ms', [GetTickCount64 - GProfT0]));
  {$ELSE}
  TinaFrame(W, H, Density);
  {$ENDIF}
end;

{ (profiling is compiled in only with -dTINA_PROFILE; release builds omit it) }

{ ---- ThreePascal demo: the walking Merino ram, rendered in pure software and
  blitted onto the hardware android.graphics.Canvas as one ARGB_8888 bitmap
  (the same DrawRGBA fast path the pure-Pascal raster canvas uses). The twin of
  the iOS tina4_sheep_frame / the macOS Sheep3D app — same engine, same model. }
var
  GSScene: TScene = nil; GSCam: TPerspectiveCamera; GSRend: TWebGLRenderer;
  GSMixer: TAnimationMixer; GST: single = 0;
  GSBuf: array of Cardinal;     // $AARRGGBB, what DrawRGBA expects

procedure Java_com_tina4_pascal_Tina4View_nativeSheepPaint(Env: PJNIEnv; This: jobject;
  Canvas: jobject; W, H: jint; Density: jfloat); cdecl;
var amb: TAmbientLight; sun: TDirectionalLight; floor: TMesh; sheep: TGroup;
    i, n, rw, rh: Integer; src: PByte; sc: single;
    {$IFDEF TINA_PROFILE}t0: QWord;{$ENDIF}
begin
  if GCanvas = nil then
  begin
    GCanvas := TAndroidCanvas.Create(Env);
    GShell := TAndroidShell.Create(GCanvas);
    GCanvas.SetAssetBase(GAssetBase);
    TinaInit(GCanvas);
  end;
  if (W <= 0) or (H <= 0) then Exit;
  {$IFDEF TINA_PROFILE}t0 := GetTickCount64;{$ENDIF}

  { Render at logical (CSS-px) resolution — the same workload the iPhone has, where
    drawRect is already in points — then let DrawRGBA scale the bitmap up to the full
    device-pixel canvas. Software rasterising all 1080x2400 native pixels is ~7x the
    fill and was the slowdown; a device-independent-pixel buffer is crisp enough. }
  sc := Density; if sc < 1 then sc := 1;
  rw := Round(W/sc); if rw < 1 then rw := 1;
  rh := Round(H/sc); if rh < 1 then rh := 1;

  if GSScene = nil then
  begin
    GSScene := TScene.Create; GSScene.Background.SetHex($0e0f1f);
    GSCam := TPerspectiveCamera.Create(45, rw/rh, 0.05, 100);
    GSRend := TWebGLRenderer.Create(rw, rh, 1); GSRend.EdgeAA := True;
    amb := TAmbientLight.Create($ffffff, 0.55); GSScene.Add(amb);
    sun := TDirectionalLight.Create($fff4cf, 0.8); sun.Position.SetXYZ(4, 9, 5); GSScene.Add(sun);
    floor := TMesh.Create(TPlaneGeometry.Create(30, 30), TMeshStandardMaterial.Create($1b7a3a));
    floor.Rotation.x := -Pi/2; GSScene.Add(floor);
    sheep := BuildRam; GSScene.Add(sheep);
    GSMixer := TAnimationMixer.Create(sheep); GSMixer.Play(RamWalkClip);
  end
  else if (GSRend.Width <> rw) or (GSRend.Height <> rh) then
  begin GSRend.SetSize(rw, rh); GSCam.Aspect := rw/rh; GSCam.UpdateProjectionMatrix; end;

  GST := GST + 1/60;
  GSCam.Position.SetXYZ(Sin(GST*0.5)*2.9, 1.4, Cos(GST*0.5)*2.9); GSCam.LookAt(0, 0.72, 0);
  GSMixer.Update(1/60);
  GSRend.Render(GSScene, GSCam);

  { ThreePascal packs pixels R,G,B,A; DrawRGBA wants $AARRGGBB (android Color int) }
  n := rw*rh;
  if System.Length(GSBuf) <> n then SetLength(GSBuf, n);
  src := @GSRend.Pixels[0];
  for i := 0 to n-1 do
  begin
    GSBuf[i] := $FF000000 or (Cardinal(src[0]) shl 16) or (Cardinal(src[1]) shl 8) or Cardinal(src[2]);
    Inc(src, 4);
  end;

  GCanvas.BeginFrame(Env, Canvas);
  GCanvas.DrawRGBA(@GSBuf[0], rw, rh, 0, 0, W, H);   // scale DIP buffer → full canvas
  {$IFDEF TINA_PROFILE}AndroidLog(Format('sheep %d ms  %dx%d -> %dx%d', [GetTickCount64 - t0, rw, rh, W, H]));{$ENDIF}
end;

function Java_com_tina4_pascal_Tina4View_nativeTouch(Env: PJNIEnv; This: jobject;
  Action: jint; X, Y: jfloat): jint; cdecl;
begin
  Result := TinaTouch(Action, X, Y);
end;

function Java_com_tina4_pascal_Tina4View_nativeTick(Env: PJNIEnv; This: jobject): jint; cdecl;
begin
  Result := TinaTick;
end;

function Java_com_tina4_pascal_Tina4View_nativeAnimActive(Env: PJNIEnv; This: jobject): jint; cdecl;
begin
  Result := TinaAnimActive;
end;

procedure Java_com_tina4_pascal_Tina4View_nativeSetAssetBase(Env: PJNIEnv; This: jobject; Dir: jstring); cdecl;
begin
  GAssetBase := JToStr(Env, Dir);
  if GCanvas <> nil then GCanvas.SetAssetBase(GAssetBase);
end;

procedure Java_com_tina4_pascal_Tina4View_nativeBlur(Env: PJNIEnv; This: jobject); cdecl;
begin
  TinaBlurInput;
end;

function Java_com_tina4_pascal_Tina4View_nativeBlinkCaret(Env: PJNIEnv; This: jobject): jint; cdecl;
begin
  Result := TinaBlinkCaret;
end;

procedure Java_com_tina4_pascal_Tina4View_nativeKey(Env: PJNIEnv; This: jobject;
  Codepoint: jint); cdecl;
begin
  TinaKey(Codepoint);
end;

function Java_com_tina4_pascal_Tina4View_nativeFocusKind(Env: PJNIEnv; This: jobject): jint; cdecl;
begin
  Result := TinaFocusKind;
end;

function Java_com_tina4_pascal_Tina4View_nativeFocusNext(Env: PJNIEnv; This: jobject): jint; cdecl;
begin
  Result := TinaFocusNext;
end;

procedure Java_com_tina4_pascal_Tina4View_nativeSetFile(Env: PJNIEnv; This: jobject;
  Name: jstring); cdecl;
begin
  TinaSetFile(JToStr(Env, Name));
end;

procedure Java_com_tina4_pascal_Tina4View_nativeSetPhoto(Env: PJNIEnv; This: jobject;
  Path: jstring); cdecl;
begin
  TinaSetPhoto(JToStr(Env, Path));
end;

{ ---- native media embeds (<video>) ----------------------------------- }

function Java_com_tina4_pascal_Tina4View_nativeEmbedCount(Env: PJNIEnv;
  This: jobject): jint; cdecl;
begin
  Result := TinaEmbedCount;
end;

{ [x, y, w, h] screen-point rect for the given embed (scroll applied). }
function Java_com_tina4_pascal_Tina4View_nativeEmbedRect(Env: PJNIEnv;
  This: jobject; Index: jint): jfloatArray; cdecl;
var x, y, w, h: Single; f: array[0..3] of jfloat;
begin
  TinaEmbedRect(Index, x, y, w, h);
  f[0] := x; f[1] := y; f[2] := w; f[3] := h;
  Result := Env^.NewFloatArray(Env, 4);
  if Result <> nil then Env^.SetFloatArrayRegion(Env, Result, 0, 4, @f[0]);
end;

function Java_com_tina4_pascal_Tina4View_nativeEmbedSrc(Env: PJNIEnv;
  This: jobject; Index: jint): jstring; cdecl;
var s: AnsiString;
begin
  s := TinaEmbedSrc(Index);
  Result := Env^.NewStringUTF(Env, PAnsiChar(s));
end;

{ boolean <video> attributes: bit0 controls·1 autoplay·2 loop·3 muted }
function Java_com_tina4_pascal_Tina4View_nativeEmbedFlags(Env: PJNIEnv;
  This: jobject; Index: jint): jint; cdecl;
begin
  Result := TinaEmbedFlags(Index);
end;

function Java_com_tina4_pascal_Tina4View_nativeEmbedKind(Env: PJNIEnv;
  This: jobject; Index: jint): jint; cdecl;
begin
  Result := TinaEmbedKind(Index);   // 0 = video · 1 = audio · 2 = barcode-scanner
end;

function Java_com_tina4_pascal_Tina4View_nativeEmbedFormats(Env: PJNIEnv;
  This: jobject; Index: jint): jstring; cdecl;
var s: AnsiString;
begin
  s := TinaEmbedFormats(Index);     // scanner symbologies ("qr,ean13,…")
  Result := Env^.NewStringUTF(Env, PAnsiChar(s));
end;

{ Java reports a decoded barcode for scanner embed Index → engine fires onscan +
  fills result="#id". Returns 1 if handled. }
function Java_com_tina4_pascal_Tina4View_nativeScanResult(Env: PJNIEnv;
  This: jobject; Index: jint; Value, Fmt: jstring): jint; cdecl;
begin
  if TinaScanResult(Index, JToStr(Env, Value), JToStr(Env, Fmt)) then Result := 1 else Result := 0;
end;

exports
  Java_com_tina4_pascal_Tina4View_nativeSetHtml,
  Java_com_tina4_pascal_Tina4View_nativePaint,
  Java_com_tina4_pascal_Tina4View_nativeSheepPaint,
  Java_com_tina4_pascal_Tina4View_nativeTouch,
  Java_com_tina4_pascal_Tina4View_nativeTick,
  Java_com_tina4_pascal_Tina4View_nativeAnimActive,
  Java_com_tina4_pascal_Tina4View_nativeSetAssetBase,
  Java_com_tina4_pascal_Tina4View_nativeWantsKeyboard,
  Java_com_tina4_pascal_Tina4View_nativeBlur,
  Java_com_tina4_pascal_Tina4View_nativeBlinkCaret,
  Java_com_tina4_pascal_Tina4View_nativeKey,
  Java_com_tina4_pascal_Tina4View_nativeFocusKind,
  Java_com_tina4_pascal_Tina4View_nativeFocusNext,
  Java_com_tina4_pascal_Tina4View_nativeSetFile,
  Java_com_tina4_pascal_Tina4View_nativeSetPhoto,
  Java_com_tina4_pascal_Tina4View_nativeEmbedCount,
  Java_com_tina4_pascal_Tina4View_nativeEmbedRect,
  Java_com_tina4_pascal_Tina4View_nativeEmbedSrc,
  Java_com_tina4_pascal_Tina4View_nativeEmbedFlags,
  Java_com_tina4_pascal_Tina4View_nativeEmbedKind,
  Java_com_tina4_pascal_Tina4View_nativeEmbedFormats,
  Java_com_tina4_pascal_Tina4View_nativeScanResult,
  Java_com_tina4_pascal_Http_nativeHttpResult,
  Java_com_tina4_pascal_ImageLoader_nativeImageReady,
  JNI_OnLoad;

begin
end.
