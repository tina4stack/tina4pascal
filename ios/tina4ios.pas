library tina4ios;

{ C-ABI bridge for the Tina4Pascal iOS shell.

  A thin shim, exactly like the Android JNI host: it creates the iOS canvas
  (Core Graphics / Core Text) and forwards every call to the shared, portable
  Tina4Interact engine. The Obj-C UIView (Tina4View.m) links this as a static
  library and calls these `tina4_*` functions — passing the drawRect CGContext
  straight through to tina4_frame.

  Build (device): see ios/build.sh — compiles for -Tios -Paarch64 and bundles
  the FPC objects into libtina4ios.a for Xcode to link. }

{$mode delphi}{$H+}

uses
  ctypes,
  CGContext,
  Tina4RenderBackend, Tina4ShellIOS, Tina4Interact, Tina4Http, Tina4HttpIOS;

var
  GCanvas: TIOSCanvas = nil;

procedure EnsureCanvas;
begin
  if GCanvas = nil then
  begin
    GCanvas := TIOSCanvas.Create;
    TinaInit(GCanvas);
    InstallIOSHttp;          // native NSURLSession HTTP backend
  end;
end;

procedure tina4_set_html(Html: PAnsiChar); cdecl;
begin
  EnsureCanvas;
  TinaSetHtml(string(Html));
end;

procedure tina4_frame(Ctx: Pointer; W, H: cint; Density: single); cdecl;
begin
  EnsureCanvas;
  HttpPump;                  // deliver completed HTTP responses on the main thread
  GCanvas.BeginFrame(CGContextRef(Ctx));
  TinaFrame(W, H, Density);
end;

function tina4_touch(Action: cint; X, Y: single): cint; cdecl;
begin
  Result := TinaTouch(Action, X, Y);
end;

function tina4_tick: cint; cdecl;
begin
  Result := TinaTick;
end;

function tina4_wants_keyboard: cint; cdecl;
begin
  Result := TinaWantsKeyboard;
end;

procedure tina4_blur; cdecl;
begin
  TinaBlurInput;
end;

function tina4_blink_caret: cint; cdecl;
begin
  Result := TinaBlinkCaret;
end;

procedure tina4_key(Codepoint: cint); cdecl;
begin
  TinaKey(Codepoint);
end;

function tina4_focus_kind: cint; cdecl;
begin
  Result := TinaFocusKind;
end;

function tina4_focus_next: cint; cdecl;
begin
  Result := TinaFocusNext;
end;

procedure tina4_set_file(Name: PAnsiChar); cdecl;
begin
  TinaSetFile(string(Name));
end;

procedure tina4_set_photo(Path: PAnsiChar); cdecl;
begin
  TinaSetPhoto(string(Path));
end;

exports
  tina4_set_html, tina4_frame, tina4_touch, tina4_tick, tina4_wants_keyboard,
  tina4_blur, tina4_blink_caret, tina4_key, tina4_focus_kind, tina4_focus_next,
  tina4_set_file, tina4_set_photo;

begin
end.
