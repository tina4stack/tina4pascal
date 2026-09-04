library tina4jni;

{ JNI entry points for the Tina4Pascal Android shell.

  Exposes the native renderer to Java (com.tina4.pascal.Tina4View):
    nativeSetHtml(String)          — set the document to render
    nativePaint(Canvas, int w,h)   — lay out (if needed) and paint a frame
    nativeTouch(int action, x, y)  — deliver a touch (tap → onclick / link)

  All layout + painting happens inside these JNI calls, so the JNIEnv is live
  while the core measures text through the Android canvas. Mirrors the desktop
  htmlviewer, minus the OS window (Android's View owns that). }

{$mode delphi}{$H+}

uses
  SysUtils, Classes,
  jni,
  Tina4HTMLDom, Tina4RenderBackend, Tina4HTMLLayout, Tina4ShellAndroid;

var
  GCanvas: TAndroidCanvas = nil;
  GShell: TAndroidShell = nil;
  GParser: THTMLParser = nil;
  GSheet: TCSSStyleSheet = nil;
  GEngine: TLayoutEngine = nil;
  GRoot: TLayoutBox = nil;
  GHtml: string = '';
  GDirty: Boolean = True;
  GLayoutW: Single = -1;

function BodyBg: TTina4Color;
begin
  Result := $FFFFFFFF;   // default page background
end;

procedure Relayout(Env: PJNIEnv; W: Single);
var i: Integer;
begin
  if GParser <> nil then GParser.Free;
  if GSheet <> nil then GSheet.Free;
  if GEngine <> nil then GEngine.Free;
  if GRoot <> nil then GRoot.Free;

  GParser := THTMLParser.Create;
  GParser.Parse(GHtml);
  GSheet := TCSSStyleSheet.Create;
  for i := 0 to GParser.StyleBlocks.Count - 1 do
    GSheet.AddCSS(GParser.StyleBlocks[i]);

  GEngine := TLayoutEngine.Create(GCanvas, GSheet);
  GRoot := GEngine.Build(GParser.Root, W);
  GLayoutW := W;
  GDirty := False;
end;

function CountSVG(Box: TLayoutBox): Integer;
var c: TLayoutBox;
begin
  Result := 0;
  if Box = nil then Exit;
  if Box.IsSVG then Inc(Result);
  for c in Box.Children do Result := Result + CountSVG(c);
end;

procedure Java_com_tina4_pascal_Tina4View_nativeSetHtml(Env: PJNIEnv; This: jobject;
  Html: jstring); cdecl;
var p: PAnsiChar;
begin
  if Html = nil then Exit;
  p := Env^.GetStringUTFChars(Env, Html, nil);
  try
    GHtml := string(p);
  finally
    Env^.ReleaseStringUTFChars(Env, Html, p);
  end;
  GDirty := True;
end;

procedure Java_com_tina4_pascal_Tina4View_nativePaint(Env: PJNIEnv; This: jobject;
  Canvas: jobject; W, H: jint); cdecl;
begin
  if GCanvas = nil then
  begin
    GCanvas := TAndroidCanvas.Create(Env);
    GShell := TAndroidShell.Create(GCanvas);
  end;
  GCanvas.BeginFrame(Env, Canvas);
  // white page
  GCanvas.FillRect(0, 0, W, H, BodyBg);
  if GHtml = '' then Exit;
  if GDirty or (Abs(GLayoutW - W) > 0.5) then
  begin
    Relayout(Env, W);
    AndroidLog('layout w=' + IntToStr(W) + ' h=' + IntToStr(H) +
      ' svg=' + IntToStr(CountSVG(GRoot)));
  end;
  if GRoot <> nil then
    PaintBox(GCanvas, GRoot, 0);
end;

procedure Java_com_tina4_pascal_Tina4View_nativeTouch(Env: PJNIEnv; This: jobject;
  Action: jint; X, Y: jfloat); cdecl;
var
  hit: THTMLTag;
begin
  // Action: 0=down 1=up 2=move (matches MotionEvent ACTION_* we pass from Java)
  if (Action = 1) and (GRoot <> nil) then
  begin
    hit := HitTest(GRoot, X, Y);
    // walk up to the nearest onclick / link; a real app routes this to its
    // handler. For now we just mark dirty so state-driven demos can re-render.
    while (hit <> nil) and not hit.HasAttribute('onclick') and
          not SameText(hit.TagName, 'a') do
      hit := hit.Parent;
    if hit <> nil then GDirty := True;
  end;
end;

exports
  Java_com_tina4_pascal_Tina4View_nativeSetHtml,
  Java_com_tina4_pascal_Tina4View_nativePaint,
  Java_com_tina4_pascal_Tina4View_nativeTouch;

begin
end.
