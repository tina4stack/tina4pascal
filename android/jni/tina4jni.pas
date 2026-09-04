library tina4jni;

{ JNI entry points for the Tina4Pascal Android shell.

  Java (com.tina4.pascal.Tina4View):
    nativeSetHtml(String)               — document ("@demo" = built-in demo)
    nativePaint(Canvas, w, h, density)  — lay out (if needed) + paint a frame
    nativeTouch(action, x, y)           — drag=scroll(+fling), tap=onclick/focus;
                                          returns 1 show kbd, 2 hide, 3 start fling
    nativeTick()                        — advance fling momentum; 1 = keep going
    nativeKey(codepoint)                — typed char (8 = backspace)

  Density: Android gives physical pixels; we lay out in CSS px (= px/density)
  and scale the canvas up, so text is a sensible physical size and media
  queries see a phone-width viewport. onclick is routed through Tina4Events
  to registered handlers — the real app model, not a hardcoded switch. }

{$mode delphi}{$H+}

uses
  SysUtils, Classes,
  jni,
  Tina4HTMLDom, Tina4RenderBackend, Tina4HTMLLayout, Tina4Events, Tina4ShellAndroid;

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
  GDensity: Single = 1;
  GViewH: Single = 0;           // CSS px
  GScrollY: Single = 0;         // CSS px
  // touch + momentum (all CSS px)
  GDownY, GLastY, GVel, GFlingV: Single;
  GMoved: Boolean = False;
  // demo state
  GDemo: Boolean = False;
  GCount: Integer = 0;
  GInput: string = '';
  GInputFocused: Boolean = False;
  GWantKeyboard: Boolean = False;
  GActionsReady: Boolean = False;

{ ---- interactive demo document (state → HTML) ------------------------- }
function BuildDemo: string;
var i: Integer; list: string;
begin
  list := '';
  for i := 1 to 30 do
    list := list + '<div class="item">Scrollable row ' + IntToStr(i) + '</div>';
  Result :=
    '<!doctype html><html><head><style>' +
    'body{font-family:sans-serif;background:#fbfaf7;color:#15162e;margin:0;padding:16px}' +
    'h1{font-size:22px;margin:0 0 2px}.sub{color:#5b5c78;margin:0 0 16px;font-size:13px}' +
    '.card{background:#fff;border:1px solid #e6e5f0;border-radius:16px;padding:16px;margin-bottom:12px}' +
    '.big{font-size:40px;font-weight:bold;color:#4F46E5}' +
    '.btn{background:#4F46E5;color:#fff;border-radius:11px;padding:12px 18px;font-weight:bold;font-size:18px}' +
    '.btn2{background:#f3f2fb;color:#15162e;border:1px solid #e6e5f0;border-radius:11px;padding:12px 16px}' +
    '.rowc{display:flex;gap:10px;align-items:center}' +
    '.item{padding:12px;border-bottom:1px solid #eee}' +
    'input{border:1px solid #c9c8dd;border-radius:10px;padding:12px;font-size:16px}' +
    '</style></head><body>' +
    '<h1>Interactive demo</h1>' +
    '<p class="sub">Scroll (with fling) · tap buttons · type — native Free Pascal.</p>' +
    '<div class="card"><div class="rowc">' +
      '<span class="btn2" onclick="Counter:Dec()">' + #$E2#$88#$92 + '</span>' +
      '<span class="big">' + IntToStr(GCount) + '</span>' +
      '<span class="btn" onclick="Counter:Inc()">+</span>' +
      '<span class="btn2" onclick="Counter:Reset()">reset</span>' +
    '</div></div>' +
    '<div class="card">' +
      '<div class="sub" style="margin-bottom:8px">Tap the box, type on the keyboard:</div>' +
      '<input type="text" value="' + GInput + '" onclick="Input:Focus()">' +
    '</div>' +
    '<div class="card" style="padding:0">' + list + '</div>' +
    '</body></html>';
end;

{ ---- registered actions (the app model) ------------------------------- }
procedure ActInc(const Args: string);   begin Inc(GCount); end;
procedure ActDec(const Args: string);   begin Dec(GCount); end;
procedure ActReset(const Args: string); begin GCount := 0; end;
procedure ActFocus(const Args: string);
begin GInputFocused := True; GWantKeyboard := True; end;

procedure EnsureActions;
begin
  if GActionsReady then Exit;
  RegisterAction('Counter:Inc', @ActInc);
  RegisterAction('Counter:Dec', @ActDec);
  RegisterAction('Counter:Reset', @ActReset);
  RegisterAction('Input:Focus', @ActFocus);
  GActionsReady := True;
end;

function BodyBg: TTina4Color; begin Result := $FFFBFAF7; end;

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
  EnsureActions;
  if Html = nil then Exit;
  p := Env^.GetStringUTFChars(Env, Html, nil);
  try GHtml := string(p);
  finally Env^.ReleaseStringUTFChars(Env, Html, p); end;
  if GHtml = '@demo' then begin GDemo := True; GHtml := BuildDemo; end;
  GScrollY := 0; GFlingV := 0; GDirty := True;
end;

procedure Java_com_tina4_pascal_Tina4View_nativePaint(Env: PJNIEnv; This: jobject;
  Canvas: jobject; W, H: jint; Density: jfloat); cdecl;
var cssW, cssH: Single;
begin
  if GCanvas = nil then
  begin
    GCanvas := TAndroidCanvas.Create(Env);
    GShell := TAndroidShell.Create(GCanvas);
  end;
  if Density > 0 then GDensity := Density;
  cssW := W / GDensity; cssH := H / GDensity;
  GViewH := cssH;
  GCanvas.BeginFrame(Env, Canvas);
  GCanvas.Scale(GDensity, GDensity);          // CSS px → physical px
  GCanvas.FillRect(0, 0, cssW, cssH, BodyBg);
  if GHtml = '' then Exit;
  if GDirty or (Abs(GLayoutW - cssW) > 0.5) then
    Relayout(Env, cssW);
  ClampScroll;
  if GRoot <> nil then PaintBox(GCanvas, GRoot, GScrollY);
end;

function Java_com_tina4_pascal_Tina4View_nativeTouch(Env: PJNIEnv; This: jobject;
  Action: jint; X, Y: jfloat): jint; cdecl;
var
  hit: THTMLTag;
  cx, cy, dy: Single;
begin
  Result := 0;
  if GRoot = nil then Exit;
  cx := X / GDensity; cy := Y / GDensity;    // device px → CSS px
  case Action of
    0: begin GDownY := cy; GLastY := cy; GVel := 0; GFlingV := 0; GMoved := False; end;
    2: begin
         dy := cy - GLastY; GLastY := cy;
         if Abs(cy - GDownY) > 6 then GMoved := True;
         GVel := GVel * 0.6 + dy * 0.4;        // smoothed velocity
         GScrollY := GScrollY - dy; ClampScroll;
       end;
    1: begin
         if GMoved then
         begin
           if Abs(GVel) > 1.5 then begin GFlingV := GVel; Result := 3; end; // fling
           Exit;
         end;
         // a tap
         hit := HitTest(GRoot, cx, cy + GScrollY);
         if (hit = nil) or
            (not SameText(hit.TagName, 'input') and
             ((hit.Parent = nil) or not SameText(hit.Parent.TagName, 'input'))) then
           if GInputFocused then begin GInputFocused := False; Result := 2; end;
         while (hit <> nil) and not hit.HasAttribute('onclick') do hit := hit.Parent;
         if hit <> nil then
         begin
           GWantKeyboard := False;
           if DispatchAction(hit.GetAttribute('onclick')) and GDemo then
           begin GHtml := BuildDemo; GDirty := True; end;
           if GWantKeyboard then Result := 1;   // focus handler asked for kbd
         end;
       end;
  end;
end;

function Java_com_tina4_pascal_Tina4View_nativeTick(Env: PJNIEnv; This: jobject): jint; cdecl;
begin
  Result := 0;
  if GFlingV = 0 then Exit;
  GScrollY := GScrollY - GFlingV;
  GFlingV := GFlingV * 0.92;                    // friction
  if (GScrollY <= 0) or (GScrollY >= MaxScroll) then GFlingV := 0;
  ClampScroll;
  if Abs(GFlingV) < 0.4 then GFlingV := 0;
  if GFlingV <> 0 then Result := 1;
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
  Java_com_tina4_pascal_Tina4View_nativeTick,
  Java_com_tina4_pascal_Tina4View_nativeKey;

begin
end.
