library tina4jni;

{ JNI entry points for the Tina4Pascal Android shell.

  Exposes the native renderer to Java (com.tina4.pascal.Tina4View):
    nativeSetHtml(String)          — set the document ("@demo" = built-in demo)
    nativePaint(Canvas, int w,h)   — lay out (if needed) and paint a frame
    nativeTouch(int action, x, y)  — drag = scroll, tap = onclick/link/focus;
                                     returns 1 to show the keyboard, 2 to hide
    nativeKey(int codepoint)       — a typed character (8 = backspace)

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
  GViewH: Single = 0;
  GScrollY: Single = 0;
  // touch tracking
  GDownY, GLastY: Single;
  GMoved: Boolean = False;
  // built-in interactive demo state
  GDemo: Boolean = False;
  GCount: Integer = 0;
  GInput: string = '';
  GInputFocused: Boolean = False;

{ ---- interactive demo document (state → HTML, the Tina4 model) --------- }
function BuildDemo: string;
var
  i: Integer;
  list: string;
begin
  list := '';
  for i := 1 to 30 do
    list := list + '<div class="item">Scrollable row ' + IntToStr(i) + '</div>';
  Result :=
    '<!doctype html><html><head><style>' +
    'body{font-family:sans-serif;background:#fbfaf7;color:#15162e;margin:0;padding:20px}' +
    'h1{font-size:24px;margin:0 0 2px}.sub{color:#5b5c78;margin:0 0 18px;font-size:13px}' +
    '.card{background:#fff;border:1px solid #e6e5f0;border-radius:16px;padding:18px;margin-bottom:14px}' +
    '.big{font-size:44px;font-weight:bold;color:#4F46E5}' +
    '.btn{background:#4F46E5;color:#fff;border-radius:11px;padding:14px 20px;font-weight:bold;font-size:18px}' +
    '.btn2{background:#f3f2fb;color:#15162e;border:1px solid #e6e5f0;border-radius:11px;padding:14px 18px}' +
    '.rowc{display:flex;gap:12px;align-items:center}' +
    '.item{padding:12px;border-bottom:1px solid #eee}' +
    'input{border:1px solid #c9c8dd;border-radius:10px;padding:12px;font-size:16px}' +
    '</style></head><body>' +
    '<h1>Interactive demo</h1>' +
    '<p class="sub">Scroll · tap buttons · type — all native Free Pascal.</p>' +
    '<div class="card"><div class="rowc">' +
      '<span class="btn2" onclick="dec">' + #$E2#$88#$92 + '</span>' +   // minus
      '<span class="big">' + IntToStr(GCount) + '</span>' +
      '<span class="btn" onclick="inc">+</span>' +
      '<span class="btn2" onclick="reset">reset</span>' +
    '</div></div>' +
    '<div class="card">' +
      '<div class="sub" style="margin-bottom:8px">Tap the box, type on the keyboard:</div>' +
      '<input type="text" value="' + GInput + '" onclick="focus">' +
    '</div>' +
    '<div class="card" style="padding:0">' + list + '</div>' +
    '</body></html>';
end;

function BodyBg: TTina4Color;
begin
  Result := $FFFBFAF7;
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

function MaxScroll: Single;
begin
  if GRoot = nil then Exit(0);
  Result := GRoot.H - GViewH;
  if Result < 0 then Result := 0;
end;

procedure ClampScroll;
begin
  if GScrollY < 0 then GScrollY := 0;
  if GScrollY > MaxScroll then GScrollY := MaxScroll;
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
  if GHtml = '@demo' then begin GDemo := True; GHtml := BuildDemo; end;
  GScrollY := 0;
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
  GViewH := H;
  GCanvas.FillRect(0, 0, W, H, BodyBg);
  if GHtml = '' then Exit;
  if GDirty or (Abs(GLayoutW - W) > 0.5) then
    Relayout(Env, W);
  ClampScroll;
  if GRoot <> nil then
    PaintBox(GCanvas, GRoot, GScrollY);
end;

{ interpret an onclick handler from the demo document }
function HandleAction(const Handler: string): jint;
begin
  Result := 0;
  if Handler = 'inc' then Inc(GCount)
  else if Handler = 'dec' then Dec(GCount)
  else if Handler = 'reset' then GCount := 0
  else if Handler = 'focus' then
  begin
    GInputFocused := True;
    Result := 1;    // ask Java to show the soft keyboard
  end;
  if GDemo then begin GHtml := BuildDemo; GDirty := True; end;
end;

function Java_com_tina4_pascal_Tina4View_nativeTouch(Env: PJNIEnv; This: jobject;
  Action: jint; X, Y: jfloat): jint; cdecl;
var
  hit: THTMLTag;
  dy: Single;
begin
  Result := 0;
  if GRoot = nil then Exit;
  case Action of
    0: begin GDownY := Y; GLastY := Y; GMoved := False; end;   // down
    2: begin                                                    // move → scroll
         dy := Y - GLastY; GLastY := Y;
         if Abs(Y - GDownY) > 8 then GMoved := True;
         GScrollY := GScrollY - dy; ClampScroll;
       end;
    1: begin                                                    // up
         if GMoved then Exit;                                   // a scroll, not a tap
         hit := HitTest(GRoot, X, Y + GScrollY);
         // tapping outside any input dismisses the keyboard
         if (hit = nil) or
            (not SameText(hit.TagName, 'input') and (hit.Parent <> nil) and
             not SameText(hit.Parent.TagName, 'input')) then
         begin
           if GInputFocused then begin GInputFocused := False; Result := 2; end;
         end;
         while (hit <> nil) and not hit.HasAttribute('onclick') do hit := hit.Parent;
         if hit <> nil then Result := HandleAction(hit.GetAttribute('onclick'));
       end;
  end;
end;

procedure Java_com_tina4_pascal_Tina4View_nativeKey(Env: PJNIEnv; This: jobject;
  Codepoint: jint); cdecl;
begin
  if not GInputFocused then Exit;
  if Codepoint = 8 then
  begin
    if Length(GInput) > 0 then Delete(GInput, Length(GInput), 1);
  end
  else if Codepoint >= 32 then
    GInput := GInput + Char(Codepoint);
  if GDemo then begin GHtml := BuildDemo; GDirty := True; end;
end;

exports
  Java_com_tina4_pascal_Tina4View_nativeSetHtml,
  Java_com_tina4_pascal_Tina4View_nativePaint,
  Java_com_tina4_pascal_Tina4View_nativeTouch,
  Java_com_tina4_pascal_Tina4View_nativeKey;

begin
end.
