unit Tina4RenderBackend;

{ Platform contract for the Tina4 native-pascal HTML renderer.
  See ARCHITECTURE.md: the layout/paint core talks ONLY to these
  abstract classes; each OS supplies a small shell implementing them.
  Coordinates are CSS pixels, origin top-left. Colors are $AARRGGBB. }

{$mode delphi}{$H+}

interface

type
  TTina4Color = Cardinal; // $AARRGGBB

  TTina4FontStyle = (tfsBold, tfsItalic, tfsUnderline);
  TTina4FontStyles = set of TTina4FontStyle;

  TTina4TextMetrics = record
    Width: Single;
    Ascent: Single;   // baseline offset from top
    Descent: Single;
    LineHeight: Single;
  end;

  TTina4Canvas = class
  public
    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); virtual; abstract;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); virtual; abstract;
    { Rounded variants; default falls back to square corners so simple
      backends (headless/null) stay correct. }
    procedure FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color); virtual;
    procedure StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color); virtual;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); virtual; abstract;
    { Draws text with (X,Y) as the TOP-LEFT of the text box. }
    procedure DrawText(X, Y: Single; const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color); virtual; abstract;
    function MeasureText(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles): TTina4TextMetrics; virtual; abstract;
    procedure SetClip(X, Y, W, H: Single); virtual; abstract;
    procedure ClearClip; virtual; abstract;
    { Images: LoadImage fetches (http/https or local path) and decodes,
      returning a handle (-1 on failure) that stays valid for the canvas
      lifetime; repeated calls with the same Src are cached. Default
      implementation supports nothing — backends override. }
    function LoadImage(const Src: string): Integer; virtual;
    function ImageSize(Handle: Integer; out W, H: Single): Boolean; virtual;
    procedure DrawImage(Handle: Integer; X, Y, W, H: Single); virtual;
  end;

  TTina4PaintEvent = procedure(Canvas: TTina4Canvas; Width, Height: Single) of object;
  TTina4MouseButtonEvent = procedure(X, Y: Single) of object;
  TTina4MouseMoveEvent = procedure(X, Y: Single) of object;
  TTina4ScrollEvent = procedure(DeltaX, DeltaY: Single) of object;
  TTina4ResizeEvent = procedure(Width, Height: Single) of object;

  TTina4Shell = class
  public
    OnPaint: TTina4PaintEvent;
    OnMouseDown: TTina4MouseButtonEvent;
    OnMouseUp: TTina4MouseButtonEvent;
    OnMouseMove: TTina4MouseMoveEvent;
    OnScroll: TTina4ScrollEvent;
    OnResize: TTina4ResizeEvent;
    procedure Initialize(Width, Height: Integer; const Title: string); virtual; abstract;
    procedure Invalidate; virtual; abstract;   // request repaint
    procedure Run; virtual; abstract;          // enter event loop
    procedure Quit; virtual; abstract;
    { Text measurement outside a paint cycle (layout needs this). }
    function GetMeasuringCanvas: TTina4Canvas; virtual; abstract;
  end;

implementation

procedure TTina4Canvas.FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color);
begin
  FillRect(X, Y, W, H, Color);
end;

procedure TTina4Canvas.StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color);
begin
  StrokeRect(X, Y, W, H, Thickness, Color);
end;

function TTina4Canvas.LoadImage(const Src: string): Integer;
begin
  Result := -1;
end;

function TTina4Canvas.ImageSize(Handle: Integer; out W, H: Single): Boolean;
begin
  W := 0; H := 0;
  Result := False;
end;

procedure TTina4Canvas.DrawImage(Handle: Integer; X, Y, W, H: Single);
begin
  // no-op in the base class
end;

end.
