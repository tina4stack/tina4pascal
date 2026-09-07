unit MacBlit;

{ Efficient macOS present for a ThreePascal RGBA buffer: wrap the buffer as a
  CGImage (zero copy — no BMP encode, no ImageIO decode) and hand it to a
  layer-backed view's CALayer, which the window server composites on the GPU.
  The colour space is created once and cached. Make the view layer-backed
  (view.setWantsLayer(True)) before calling Present. }

{$mode delphi}{$H+}
{$modeswitch objectivec1}

interface

uses CocoaAll;

procedure Present(view: NSView; pixels: Pointer; w, h: Integer);

implementation

{$linkframework CoreGraphics}
type
  CGImageRef = Pointer; CGColorSpaceRef = Pointer; CGDataProviderRef = Pointer;
function CGColorSpaceCreateDeviceRGB: CGColorSpaceRef; cdecl; external;
function CGDataProviderCreateWithData(a,b:Pointer;c:NativeUInt;d:Pointer):CGDataProviderRef; cdecl; external;
function CGImageCreate(w,h,bpc,bpp,bpr:NativeUInt; sp:CGColorSpaceRef; bi:LongWord;
  pr:CGDataProviderRef; dec_:Pointer; interp:LongBool; intent:LongInt):CGImageRef; cdecl; external;
procedure CGImageRelease(i:CGImageRef); cdecl; external;
procedure CGDataProviderRelease(p:CGDataProviderRef); cdecl; external;

var gCS: CGColorSpaceRef = nil;   // created once, reused every frame

procedure Present(view: NSView; pixels: Pointer; w, h: Integer);
var pr: CGDataProviderRef; img: CGImageRef;
begin
  if (view=nil) or (view.layer=nil) or (pixels=nil) or (w<=0) or (h<=0) then Exit;
  if gCS=nil then gCS:=CGColorSpaceCreateDeviceRGB;
  pr:=CGDataProviderCreateWithData(nil, pixels, NativeUInt(w)*h*4, nil);
  img:=CGImageCreate(w, h, 8, 32, NativeUInt(w)*4, gCS, 1 {PremultipliedLast}, pr, nil, False, 0);
  view.layer.setContents(id(img));
  if img<>nil then CGImageRelease(img);
  CGDataProviderRelease(pr);
end;

end.
