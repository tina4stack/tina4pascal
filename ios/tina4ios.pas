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

{ In-flight HTTP requests. The view runs a light redraw loop while this is > 0,
  so an async response (delivered on a background thread) gets pumped onto the
  main thread and painted without needing another touch. }
function tina4_http_pending: cint; cdecl;
begin
  Result := HttpPending;
end;

{ Called by the Obj-C image loader when a remote image finishes downloading to
  the cache — relayout so LoadImage decodes it and it appears. Mach-O C symbol. }
procedure tina4_image_ready; cdecl; public name '_tina4_image_ready';
begin
  TinaInvalidateLayout;
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

{ ---- native media embeds (<video>) ----------------------------------- }

function tina4_embed_count: cint; cdecl;
begin
  Result := TinaEmbedCount;
end;

procedure tina4_embed_rect(Index: cint; X, Y, W, H: PSingle); cdecl;
var xx, yy, ww, hh: Single;
begin
  TinaEmbedRect(Index, xx, yy, ww, hh);
  if X <> nil then X^ := xx;
  if Y <> nil then Y^ := yy;
  if W <> nil then W^ := ww;
  if H <> nil then H^ := hh;
end;

function tina4_embed_src(Index: cint; Buf: PAnsiChar; Cap: cint): cint; cdecl;
var s: AnsiString;
begin
  s := TinaEmbedSrc(Index);
  Result := Length(s);
  if (Buf <> nil) and (Cap > 0) then
  begin
    if Result > Cap - 1 then Result := Cap - 1;
    if Result > 0 then Move(s[1], Buf^, Result);
    Buf[Result] := #0;
  end;
end;

function tina4_embed_flags(Index: cint): cint; cdecl;
begin
  Result := TinaEmbedFlags(Index);
end;

function tina4_embed_poster(Index: cint; Buf: PAnsiChar; Cap: cint): cint; cdecl;
var s: AnsiString;
begin
  s := TinaEmbedPoster(Index);
  Result := Length(s);
  if (Buf <> nil) and (Cap > 0) then
  begin
    if Result > Cap - 1 then Result := Cap - 1;
    if Result > 0 then Move(s[1], Buf^, Result);
    Buf[Result] := #0;
  end;
end;

exports
  tina4_set_html, tina4_frame, tina4_touch, tina4_tick, tina4_http_pending,
  tina4_wants_keyboard, tina4_blur, tina4_blink_caret, tina4_key,
  tina4_focus_kind, tina4_focus_next, tina4_set_file, tina4_set_photo,
  tina4_embed_count, tina4_embed_rect, tina4_embed_src,
  tina4_embed_flags, tina4_embed_poster;

begin
end.
