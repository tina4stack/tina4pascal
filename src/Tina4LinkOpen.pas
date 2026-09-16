unit Tina4LinkOpen;

{ Cross-platform <a href> opener for the Tina4 native renderer.

  A click on an anchor the core can't handle itself (a link with no onclick /
  control) fires Tina4InvokeLink; wire this unit's handler with
  Tina4InstallLinkOpener and the URL is handed to the operating system, which
  routes it by scheme:

    <a href="tel:+27115551234">Call us</a>       → the phone dialer
    <a href="mailto:hi@tina4.com?subject=Hi">…</a> → the mail composer
    <a href="sms:+27115551234">Text us</a>        → the SMS app
    <a href="https://tina4.com">Visit</a>          → the default browser
    <a href="geo:-33.9,18.4">Map</a> / maps:…       → the maps app

  Shell-side utility — the per-OS conditionals live HERE, never in the core
  (Tina4HTMLDom / Tina4HTMLLayout stay OS-free and only call the abstract
  Tina4InvokeLink hook). Target ("_blank" etc.) is accepted for parity and
  ignored; the OS decides the surface. }

{$mode delphi}{$H+}

interface

uses
  Tina4RenderBackend;

{ Open a URL through the OS by its scheme (tel:/mailto:/sms:/http(s):/geo:/…). }
procedure Tina4OpenUrl(const Url: string);

{ The ready-made link handler and its one-line installer (call once at startup,
  after the shell is up): registers Tina4OpenUrl as the core's link hook. }
procedure Tina4DefaultLinkHandler(const Href, Target: string);
procedure Tina4InstallLinkOpener;

implementation

uses
  SysUtils
  {$IFDEF WINDOWS}, Windows, ShellApi{$ELSE}, Unix{$ENDIF};

procedure Tina4OpenUrl(const Url: string);
var u: string;
begin
  u := Trim(Url);
  if u = '' then Exit;
  {$IFDEF WINDOWS}
  ShellExecuteW(0, 'open', PWideChar(UTF8Decode(u)), nil, nil, 5 { SW_SHOW });
  {$ELSE}{$IFDEF DARWIN}
  fpSystem('open ' + QuotedStr(u));                       // routes every scheme
  {$ELSE}
  fpSystem('xdg-open ' + QuotedStr(u) + ' >/dev/null 2>&1 &');
  {$ENDIF}{$ENDIF}
end;

procedure Tina4DefaultLinkHandler(const Href, Target: string);
begin
  Tina4OpenUrl(Href);
end;

procedure Tina4InstallLinkOpener;
begin
  Tina4SetLinkHandler(@Tina4DefaultLinkHandler);
end;

end.
