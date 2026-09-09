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
  ctypes, Math,
  CGContext, CGImage, CGColorSpace, CGDataProvider, CGGeometry,
  Tina4RenderBackend, Tina4ShellIOS, Tina4Interact, Tina4Canvas2D, Tina4Http, Tina4HttpIOS,
  ThreePascal, RamModel
  { A project's own units (declared as "appUnits" in tina4.json) are spliced in
    here by the iOS build. Each registers its named actions in its own
    initialization, so the app's Pascal logic ships in libtina4ios.a without
    editing this shell. Defaults to empty (app_units.inc). }
  {$I app_units.inc} ;

var
  GCanvas: TIOSCanvas = nil;
  GAssetBase: string = '';   // app-bundle resource dir for relative <img src>

procedure EnsureCanvas;
begin
  if GCanvas = nil then
  begin
    GCanvas := TIOSCanvas.Create;
    GCanvas.SetAssetBase(GAssetBase);
    TinaInit(GCanvas);
    InstallIOSHttp;          // native NSURLSession HTTP backend
  end;
end;

procedure tina4_set_asset_base(Dir: PAnsiChar); cdecl;
begin
  GAssetBase := string(Dir);
  if GCanvas <> nil then GCanvas.SetAssetBase(GAssetBase);
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

{ ---- ThreePascal demo: the walking Merino ram, rendered in pure software and
  blitted into the drawRect CGContext as a CGImage (the mobile twin of the macOS
  example). The Obj-C view drives it with a per-frame display link. ---- }
var
  GSScene: TScene = nil; GSCam: TPerspectiveCamera; GSRend: TWebGLRenderer;
  GSMixer: TAnimationMixer; GST: single = 0;

procedure tina4_sheep_frame(Ctx: Pointer; W, H: cint; Density: single); cdecl;
var cs: CGColorSpaceRef; pr: CGDataProviderRef; img: CGImageRef;
    amb: TAmbientLight; sun: TDirectionalLight; floor: TMesh; sheep: TGroup;
begin
  if GSScene = nil then
  begin
    GSScene := TScene.Create; GSScene.Background.SetHex($0e0f1f);
    GSCam := TPerspectiveCamera.Create(45, W/H, 0.05, 100);
    GSRend := TWebGLRenderer.Create(W, H, 1); GSRend.EdgeAA := True;
    amb := TAmbientLight.Create($ffffff, 0.55); GSScene.Add(amb);
    sun := TDirectionalLight.Create($fff4cf, 0.8); sun.Position.SetXYZ(4, 9, 5); GSScene.Add(sun);
    floor := TMesh.Create(TPlaneGeometry.Create(30, 30), TMeshStandardMaterial.Create($1b7a3a));
    floor.Rotation.x := -Pi/2; GSScene.Add(floor);
    sheep := BuildRam; GSScene.Add(sheep);
    GSMixer := TAnimationMixer.Create(sheep); GSMixer.Play(RamWalkClip);
  end
  else if (GSRend.Width <> W) or (GSRend.Height <> H) then
  begin GSRend.SetSize(W, H); GSCam.Aspect := W/H; GSCam.UpdateProjectionMatrix; end;

  GST := GST + 1/60;
  GSCam.Position.SetXYZ(Sin(GST*0.5)*2.9, 1.4, Cos(GST*0.5)*2.9); GSCam.LookAt(0, 0.72, 0);
  GSMixer.Update(1/60);
  GSRend.Render(GSScene, GSCam);

  cs := CGColorSpaceCreateDeviceRGB;
  pr := CGDataProviderCreateWithData(nil, @GSRend.Pixels[0], W*H*4, nil);
  img := CGImageCreate(W, H, 8, 32, W*4, cs, kCGImageAlphaPremultipliedLast, pr, nil, 0, kCGRenderingIntentDefault);
  CGContextSaveGState(CGContextRef(Ctx));
  CGContextTranslateCTM(CGContextRef(Ctx), 0, H);        // flip: CG image is y-up, drawRect is y-down
  CGContextScaleCTM(CGContextRef(Ctx), 1, -1);
  CGContextDrawImage(CGContextRef(Ctx), CGRectMake(0, 0, W, H), img);
  CGContextRestoreGState(CGContextRef(Ctx));
  CGImageRelease(img); CGDataProviderRelease(pr); CGColorSpaceRelease(cs);
end;

{ Repaint ONLY the last frame's animated region (a UIView's layer retains the rest
  between drawRect: passes, so an animation-only frame invalidates just that rect
  via setNeedsDisplayInRect: — the natural iOS analogue of the backing-store,
  without a manual bitmap). }
procedure tina4_frame_region(Ctx: Pointer; W, H: cint; Density: single); cdecl;
begin
  EnsureCanvas;
  GCanvas.BeginFrame(CGContextRef(Ctx));
  TinaFrameRegion(W, H, Density);
end;

{ The last frame's animated region in engine points (X,Y,W,H via out pointers);
  returns 1 when a confined region is available (caller invalidates just that rect),
  else 0 (repaint fully). }
function tina4_anim_region(X, Y, W, H: PSingle): cint; cdecl;
var rx, ry, rw, rh: Single;
begin
  if AnimRegion(rx, ry, rw, rh) then
  begin
    if X <> nil then X^ := rx; if Y <> nil then Y^ := ry;
    if W <> nil then W^ := rw; if H <> nil then H^ := rh;
    Result := 1;
  end
  else Result := 0;
end;

function tina4_touch(Action: cint; X, Y: single): cint; cdecl;
begin
  Result := TinaTouch(Action, X, Y);
end;

function tina4_tick: cint; cdecl;
begin
  Result := TinaTick;
end;

{ 1 if the last frame has live animation (does NOT advance the clock) — the view
  starts its display-link loop from this so a <lottie> animates on load, not only
  after a fling. }
function tina4_anim_active: cint; cdecl;
begin
  Result := TinaAnimActive;
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

function tina4_embed_kind(Index: cint): cint; cdecl;
begin
  Result := TinaEmbedKind(Index);   // 0 = video · 1 = audio
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

{ scanner (kind 2): the requested symbologies, e.g. "qr,ean13,code128" (''=any). }
function tina4_embed_formats(Index: cint; Buf: PAnsiChar; Cap: cint): cint; cdecl;
var s: AnsiString;
begin
  s := TinaEmbedFormats(Index);
  Result := Length(s);
  if (Buf <> nil) and (Cap > 0) then
  begin
    if Result > Cap - 1 then Result := Cap - 1;
    if Result > 0 then Move(s[1], Buf^, Result);
    Buf[Result] := #0;
  end;
end;

{ the shell reports a decoded barcode for scanner embed Index → engine fires its
  onscan action + fills its result target. Returns 1 if handled. }
function tina4_scan_result(Index: cint; Value, Format: PAnsiChar): cint; cdecl;
begin
  if TinaScanResult(Index, AnsiString(Value), AnsiString(Format)) then Result := 1 else Result := 0;
end;

exports
  tina4_set_html, tina4_set_asset_base, tina4_frame, tina4_sheep_frame, tina4_frame_region, tina4_anim_region,
  tina4_touch, tina4_tick, tina4_anim_active, tina4_http_pending,
  tina4_wants_keyboard, tina4_blur, tina4_blink_caret, tina4_key,
  tina4_focus_kind, tina4_focus_next, tina4_set_file, tina4_set_photo,
  tina4_embed_count, tina4_embed_rect, tina4_embed_src,
  tina4_embed_flags, tina4_embed_poster, tina4_embed_kind,
  tina4_embed_formats, tina4_scan_result;

begin
end.
