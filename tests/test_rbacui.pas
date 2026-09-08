program test_rbacui;

{ Headless test that the RBAC guard actually hides gated UI. Loads a JWT giving
  the user role `user` + permission `read` (not `admin`/`write`), installs the
  Tina4Auth guard, lays out a page mixing data-role/data-perm elements, and
  asserts via the layout box tree that denied elements produced NO box (hidden)
  while permitted + ungated ones did. Then removes the guard and checks all
  reappear. No canvas/shell — a stub measuring canvas drives layout. }

{$mode delphi}{$H+}

uses SysUtils, DateUtils, Tina4RenderBackend, Tina4Crypto, Tina4Auth, Tina4Interact;

type
  TStubCanvas = class(TTina4Canvas)
  public
    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); override;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); override;
    procedure DrawText(X, Y: Single; const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color); override;
    function MeasureText(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles): TTina4TextMetrics; override;
    procedure SetClip(X, Y, W, H: Single); override;
    procedure ClearClip; override;
  end;
procedure TStubCanvas.FillRect(X, Y, W, H: Single; Color: TTina4Color); begin end;
procedure TStubCanvas.StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); begin end;
procedure TStubCanvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); begin end;
procedure TStubCanvas.DrawText(X, Y: Single; const Text: string; FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color); begin end;
function TStubCanvas.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
begin Result.Width := Length(Text) * FontSize * 0.5; Result.Ascent := FontSize * 0.8;
  Result.Descent := FontSize * 0.2; Result.LineHeight := FontSize * 1.4; end;
procedure TStubCanvas.SetClip(X, Y, W, H: Single); begin end;
procedure TStubCanvas.ClearClip; begin end;

var failed: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(failed); end;
end;

function MakeJWT(const P: string): string;
begin Result := Base64UrlEncode('{"alg":"none"}') + '.' + Base64UrlEncode(RawByteString(P)) + '.s'; end;

function HasBox(const BoxTree, Id: string): Boolean;
begin Result := Pos('"id":"' + Id + '"', BoxTree) > 0; end;

const
  PAGE =
    '<body>' +
    '<div id="admin-only" data-role="admin">A</div>' +
    '<div id="write-only" data-perm="invoice.write">W</div>' +
    '<div id="user-only"  data-role="user">U</div>' +
    '<div id="read-only"  data-perm="invoice.read">R</div>' +
    '<div id="always">X</div>' +
    '</body>';

var
  canvas: TStubCanvas; bt: string; future: Int64; cfg: TTina4AuthConfig;
begin
  WriteLn('== Tina4 RBAC UI guard ==');
  future := DateTimeToUnix(IncHour(Now, 1));
  canvas := TStubCanvas.Create;
  TinaInit(canvas);

  FillChar(cfg, SizeOf(cfg), 0); cfg.RolesClaim := 'roles'; cfg.PermsClaim := 'permissions';
  TinaAuthConfigure(cfg);
  TinaAuthLoadToken(MakeJWT('{"sub":"u","roles":["user"],"permissions":["invoice.read"],"exp":' +
    IntToStr(future) + '}'));
  TinaAuthInstallGuard;

  TinaSetHtml(PAGE);
  TinaLayoutOnly(360, 1.0);
  bt := TinaBoxTree;
  WriteLn('with guard (user has role=user, perm=invoice.read)');
  Check(not HasBox(bt, 'admin-only'), 'data-role="admin" hidden (user lacks it)');
  Check(not HasBox(bt, 'write-only'), 'data-perm="invoice.write" hidden');
  Check(HasBox(bt, 'user-only'), 'data-role="user" visible');
  Check(HasBox(bt, 'read-only'), 'data-perm="invoice.read" visible');
  Check(HasBox(bt, 'always'), 'ungated element visible');

  WriteLn('guard removed → everything visible');
  TinaAuthRemoveGuard;
  TinaSetHtml(PAGE);                 // re-parse → re-cascade with no guard
  TinaLayoutOnly(360, 1.0);
  bt := TinaBoxTree;
  Check(HasBox(bt, 'admin-only') and HasBox(bt, 'write-only'), 'gated elements reappear');

  WriteLn;
  if failed = 0 then begin WriteLn('ALL TESTS PASS'); Halt(0); end
  else begin WriteLn(failed, ' FAILURE(S)'); Halt(1); end;
end.
