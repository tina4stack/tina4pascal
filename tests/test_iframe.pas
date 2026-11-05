program test_iframe;
{ <iframe> as a shell-hosted embed — the engine half, checked headless (no GUI,
  no web view). The engine never renders web content: it lays the <iframe> out
  as a sized box and reports it through the TinaEmbed* API, and a shell overlays
  the OS's own web view on it (WKWebView on macOS — see plan/adr/0016). So the
  contract this suite pins down is what a shell reads each frame:
    - kind 5, the src, and the CONTENT box (inside the UA 2px frame border)
    - HTML default 300x150, width/height attributes, CSS width/height
    - the rect tracks page scroll (screen coords, like <video>)
    - a stable key (id, else "iframe:<n>") that survives a src change, so the
      shell reloads one web view in place instead of recreating it
    - display:none drops the embed (the shell removes its view)
    - fallback content inside <iframe> is never parsed or laid out }
{$mode delphi}{$H+}

uses SysUtils, Tina4RenderBackend, Tina4RasterCanvas, Tina4Interact,
     Tina4Builtins;

const VW = 800; VH = 600;

var
  Canvas: TTina4RasterCanvas;
  Fails: Integer = 0; Total: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Total);
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(Fails); end;
end;

procedure Load(const Html: string);
begin
  TinaSetHtml(Html);
  TinaFrame(VW, VH, 1);
end;

{ index of the first embed of kind 5 (iframe) with key Key ('' = any), else -1 }
function FindFrame(const Key: string): Integer;
var i: Integer;
begin
  Result := -1;
  for i := 0 to TinaEmbedCount - 1 do
    if (TinaEmbedKind(i) = 5) and ((Key = '') or (TinaEmbedKey(i) = Key)) then Exit(i);
end;

function Near(A, B: Single): Boolean;
begin Result := Abs(A - B) < 0.51; end;

var
  i, n, frames: Integer;
  x, y, w, h, y0: Single;

begin
  WriteLn('=== <iframe> embed layout ===');
  Canvas := TTina4RasterCanvas.Create(VW, VH);
  try
    TinaInit(Canvas);

    // ---- default intrinsic size + content box inside the UA border --------
    Load('<body style="margin:0"><iframe src="http://127.0.0.1:8765/"></iframe></body>');
    i := FindFrame('');
    Check(i >= 0, 'an <iframe> is reported as an embed of kind 5');
    TinaEmbedRect(i, x, y, w, h);
    Check(Near(w, 300) and Near(h, 150), Format('default content box is 300x150 (got %.1fx%.1f)', [w, h]));
    Check(Near(x, 2) and Near(y, 2), Format('rect is inset by the 2px UA frame border (got %.1f,%.1f)', [x, y]));
    Check(TinaEmbedSrc(i) = 'http://127.0.0.1:8765/', 'src is reported verbatim (a plain http://127.0.0.1 URL)');
    Check(TinaEmbedKey(i) = 'iframe:0', 'an iframe without an id is keyed by document order');

    // ---- width/height attributes ------------------------------------------
    Load('<body style="margin:0"><iframe src="https://example.com/" width="640" height="360"></iframe></body>');
    i := FindFrame('');
    TinaEmbedRect(i, x, y, w, h);
    Check(Near(w, 640) and Near(h, 360), Format('width/height attributes size the box (got %.1fx%.1f)', [w, h]));

    // ---- CSS width/height, author border:0 --------------------------------
    Load('<body style="margin:0"><iframe src="https://example.com/" ' +
         'style="width:500px;height:220px;border:0;margin-left:30px"></iframe></body>');
    i := FindFrame('');
    TinaEmbedRect(i, x, y, w, h);
    Check(Near(w, 500) and Near(h, 220), Format('CSS width/height size the box (got %.1fx%.1f)', [w, h]));
    Check(Near(x, 30) and Near(y, 0), Format('border:0 + margin: rect at the content edge (got %.1f,%.1f)', [x, y]));

    // ---- padding is excluded from the web view rect -----------------------
    Load('<body style="margin:0"><iframe src="https://example.com/" ' +
         'style="width:200px;height:100px;border:3px solid #000;padding:7px"></iframe></body>');
    i := FindFrame('');
    TinaEmbedRect(i, x, y, w, h);
    Check(Near(x, 10) and Near(y, 10) and Near(w, 200) and Near(h, 100),
      Format('border + padding are outside the web view (got %.1f,%.1f %.1fx%.1f)', [x, y, w, h]));

    // ---- fallback content is raw text, never laid out ---------------------
    Load('<body style="margin:0"><iframe id="f" src="https://example.com/" style="border:0">' +
         '<p>fallback <b>markup</b> that must not render</p></iframe>' +
         '<div id="after" style="height:10px"></div></body>');
    Check(Pos('fallback', TinaBoxTree) = 0, 'fallback content inside <iframe> is not laid out');
    Check(Pos('fallback', TinaDumpDom) = 0, 'fallback content inside <iframe> is not parsed into the DOM');
    Check(Pos('"after"', TinaBoxTree) > 0, 'markup after </iframe> still parses normally');

    // ---- the rect tracks page scroll (screen coordinates) -----------------
    Load('<body style="margin:0"><div style="height:400px"></div>' +
         '<iframe id="p" src="http://127.0.0.1:8765/" style="width:600px;height:300px;border:0"></iframe>' +
         '<div style="height:1200px"></div></body>');
    i := FindFrame('p');
    TinaEmbedRect(i, x, y0, w, h);
    Check(Near(y0, 400), Format('iframe below a 400px block starts at y=400 (got %.1f)', [y0]));
    TinaScrollBy(10, 10, 0, -150);   // -DY scrolls the page down
    TinaFrame(VW, VH, 1);
    i := FindFrame('p');
    TinaEmbedRect(i, x, y, w, h);
    Check(Near(y, y0 - 150), Format('scrolling the page 150px moves the rect up 150px (got %.1f)', [y]));

    // ---- src change keeps the same key (reload in place) ------------------
    Load('<body style="margin:0"><iframe id="preview" src="http://127.0.0.1:8765/"></iframe></body>');
    Check(FindFrame('preview') >= 0, 'an iframe with an id is keyed by its id');
    SetAttr(FindById(BuiltinsRoot, 'preview'), 'src', 'http://127.0.0.1:8765/second.html');
    TinaFrame(VW, VH, 1);
    i := FindFrame('preview');
    Check((i >= 0) and (TinaEmbedSrc(i) = 'http://127.0.0.1:8765/second.html'),
      'after a src change the same key reports the new src');

    // ---- display:none removes the embed -----------------------------------
    SetStyleProp(FindById(BuiltinsRoot, 'preview'), 'display', 'none');
    TinaFrame(VW, VH, 1);
    Check(FindFrame('preview') < 0, 'display:none drops the iframe embed (shell removes its view)');
    SetStyleProp(FindById(BuiltinsRoot, 'preview'), 'display', 'inline-block');
    TinaFrame(VW, VH, 1);
    Check(FindFrame('preview') >= 0, 'showing it again reports the embed again');

    // ---- several iframes, alongside a <video> -----------------------------
    Load('<body style="margin:0"><iframe src="https://a.example/"></iframe>' +
         '<video src="https://example.com/v.mp4"></video>' +
         '<iframe src="https://b.example/"></iframe></body>');
    n := TinaEmbedCount; frames := 0;
    for i := 0 to n - 1 do if TinaEmbedKind(i) = 5 then Inc(frames);
    Check(frames = 2, 'two iframes report two kind-5 embeds');
    Check((FindFrame('iframe:0') >= 0) and (FindFrame('iframe:1') >= 0), 'keys follow document order');
    Check((FindFrame('iframe:1') >= 0) and (TinaEmbedSrc(FindFrame('iframe:1')) = 'https://b.example/'),
      'the second key carries the second src');
    i := -1;
    for n := 0 to TinaEmbedCount - 1 do if TinaEmbedKind(n) = 0 then i := n;
    Check((i >= 0) and (TinaEmbedKey(i) = 'https://example.com/v.mp4'),
      'a <video> is still kind 0, keyed by its src');
  finally
    Canvas.Free;
  end;
  WriteLn;
  WriteLn(Total - Fails, '/', Total, ' passed');
  if Fails = 0 then begin WriteLn('ALL TESTS PASS'); Halt(0); end else Halt(1);
end.
