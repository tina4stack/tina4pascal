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
  SysUtils,
  jni,
  Tina4RenderBackend, Tina4ShellAndroid, Tina4Interact,
  Tina4Http, Tina4HttpAndroid;

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
  Result := TinaEmbedKind(Index);   // 0 = video · 1 = audio
end;

exports
  Java_com_tina4_pascal_Tina4View_nativeSetHtml,
  Java_com_tina4_pascal_Tina4View_nativePaint,
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
  Java_com_tina4_pascal_Http_nativeHttpResult,
  Java_com_tina4_pascal_ImageLoader_nativeImageReady,
  JNI_OnLoad;

begin
end.
