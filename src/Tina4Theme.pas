unit Tina4Theme;

{ Default look for renderer-drawn form controls: the Tina4 brand shape
  (soft blue-tinted neutrals, ~11px radius, calm surfaces) with an indigo
  accent for primary actions, focus and checked state. These are the UA
  defaults applied when a page's own CSS doesn't style a control; author
  CSS always wins over them. Colors are $AARRGGBB. }

{$mode delphi}{$H+}

interface

uses
  Tina4RenderBackend;

const
  // Tina4 neutrals (blue-tinted so they read as chosen, from tina4-design)
  TC_INK       : TTina4Color = $FF15162E;  // primary text
  TC_MUTED     : TTina4Color = $FF5B5C78;  // secondary text
  TC_FAINT     : TTina4Color = $FF9698B4;  // placeholder
  TC_BORDER    : TTina4Color = $FFE6E5F0;  // control border
  TC_SURFACE   : TTina4Color = $FFFFFFFF;  // input background
  TC_SURFACE2  : TTina4Color = $FFF3F2FB;  // neutral button background

  // Indigo accent (user-chosen) for primary / focus / checked
  TC_ACCENT      : TTina4Color = $FF4F46E5;
  TC_ACCENT_DEEP : TTina4Color = $FF4338CA;  // hover/active
  TC_ACCENT_SOFT : TTina4Color = $FFEEF0FF;  // hovered rows / soft fills
  TC_ON_ACCENT   : TTina4Color = $FFFFFFFF;  // text on the accent

  // Metrics
  TC_RADIUS      = 11.0;   // inputs / buttons
  TC_RADIUS_SM   = 5.0;    // checkbox
  TC_PAD_V       = 9.0;
  TC_PAD_H       = 12.0;
  TC_BTN_PAD_H   = 16.0;
  TC_BORDER_W    = 1.0;
  TC_FOCUS_W     = 2.0;    // focus border (ring not paintable yet)
  TC_CTRL_BOX    = 18.0;   // checkbox / radio side

implementation

end.
