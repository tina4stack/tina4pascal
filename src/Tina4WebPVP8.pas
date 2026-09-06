unit Tina4WebPVP8;

{ Pure-Pascal lossy VP8 (WebP) intra-frame decoder — no OS codecs, no external
  libraries. Decodes a single VP8 key frame (RFC 6386 / On2 VP8) to straight-alpha
  RGBA (R,G,B,A per pixel, top-left origin, A always 255 since VP8 lossy has no
  alpha channel). Companion to Tina4WebP (VP8L / lossless); dispatched to from
  Tina4DecodeWebP for the 'VP8 ' chunk.

  Implemented, bit-exact against dwebp (= libwebp):
   * Boolean (arithmetic) entropy decoder                     (RFC 6386 §7)
   * Frame + macroblock headers, segmentation, loop-filter    (§9)
   * Quantizer setup                                          (§14.1)
   * Coefficient token decode + DCT/WHT dequant               (§13)
   * 4x4 IDCT (20091/35468) and 4x4 inverse WHT               (§14.3/14.4)
   * Intra prediction: luma 16x16, luma 4x4 (B_PRED, 10 modes),
     chroma 8x8                                               (§12)
   * In-loop deblocking: simple + normal filters              (§15)
   * YUV 4:2:0 -> RGB with libwebp fixed-point coeffs + the
     libwebp "fancy" (bilinear) chroma upsampler.

  The reconstruction/border/top-sample handling mirrors libwebp's frame_dec.c
  (yuv_b working buffer with BPS stride) so predictor edge sampling is exact.
  Intra prediction always reads *unfiltered* reconstruction (libwebp stashes top
  samples before filtering), so the whole frame is reconstructed first and the
  in-loop filter is then applied row-by-row in raster order — bit-identical. }

{$mode delphi}{$H+}{$POINTERMATH ON}

interface

uses SysUtils;

{ Decode a raw VP8 key-frame partition (the payload of a 'VP8 ' chunk, i.e. the
  bytes starting at the 3-byte frame tag 0x9d 0x01 0x2a preamble's frame header).
  Data/Size point at the start of the VP8 bitstream (the uncompressed 10-byte
  header, then partition 0, then token partitions). Returns True with RGBA =
  W*H*4 straight-alpha bytes. }
function Tina4DecodeVP8(Data: PByte; Size: Integer; out RGBA: TBytes;
  out W, H: Integer): Boolean;

implementation

const
  BPS   = 32;                 // stride of the yuv_b working buffer
  YUV_SIZE = BPS * 17 + BPS * 9;
  Y_OFF = BPS * 1 + 8;
  U_OFF = Y_OFF + BPS * 16 + BPS;
  V_OFF = U_OFF + 16;

  // intra prediction mode ids (common_dec.h)
  B_DC_PRED = 0; B_TM_PRED = 1; B_VE_PRED = 2; B_HE_PRED = 3; B_RD_PRED = 4;
  B_VR_PRED = 5; B_LD_PRED = 6; B_VL_PRED = 7; B_HD_PRED = 8; B_HU_PRED = 9;
  DC_PRED = 0; TM_PRED = 1; V_PRED = 2; H_PRED = 3;
  B_DC_PRED_NOTOP = 4; B_DC_PRED_NOLEFT = 5; B_DC_PRED_NOTOPLEFT = 6;

  KBands: array[0..16] of Integer =
    (0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0);
  KZigzag: array[0..15] of Integer =
    (0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15);
  KScan: array[0..15] of Integer = (
    0 + 0 * BPS,  4 + 0 * BPS,  8 + 0 * BPS,  12 + 0 * BPS,
    0 + 4 * BPS,  4 + 4 * BPS,  8 + 4 * BPS,  12 + 4 * BPS,
    0 + 8 * BPS,  4 + 8 * BPS,  8 + 8 * BPS,  12 + 8 * BPS,
    0 + 12 * BPS, 4 + 12 * BPS, 8 + 12 * BPS, 12 + 12 * BPS);

  // large-value category extra-bit probabilities (§13.2)
  KCat3: array[0..2] of Byte = (173, 148, 140);
  KCat4: array[0..3] of Byte = (176, 155, 140, 135);
  KCat5: array[0..4] of Byte = (180, 157, 141, 134, 130);
  KCat6: array[0..10] of Byte = (254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129);

  {$REGION 'default probability tables (from libwebp tree_dec.c / quant_dec.c)'}
  KCoeffsProba0: array[0..1055] of Byte = (
    128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,
    128,128,128,128,128,128,128,128,128,128,128,253,136,254,255,228,219,128,128,128,128,128,
    189,129,242,255,227,213,255,219,128,128,128,106,126,227,252,214,209,255,255,128,128,128,
    1,98,248,255,236,226,255,255,128,128,128,181,133,238,254,221,234,255,154,128,128,128,
    78,134,202,247,198,180,255,219,128,128,128,1,185,249,255,243,255,128,128,128,128,128,
    184,150,247,255,236,224,128,128,128,128,128,77,110,216,255,236,230,128,128,128,128,128,
    1,101,251,255,241,255,128,128,128,128,128,170,139,241,252,236,209,255,255,128,128,128,
    37,116,196,243,228,255,255,255,128,128,128,1,204,254,255,245,255,128,128,128,128,128,
    207,160,250,255,238,128,128,128,128,128,128,102,103,231,255,211,171,128,128,128,128,128,
    1,152,252,255,240,255,128,128,128,128,128,177,135,243,255,234,225,128,128,128,128,128,
    80,129,211,255,194,224,128,128,128,128,128,1,1,255,128,128,128,128,128,128,128,128,
    246,1,255,128,128,128,128,128,128,128,128,255,128,128,128,128,128,128,128,128,128,128,
    198,35,237,223,193,187,162,160,145,155,62,131,45,198,221,172,176,220,157,252,221,1,
    68,47,146,208,149,167,221,162,255,223,128,1,149,241,255,221,224,255,255,128,128,128,
    184,141,234,253,222,220,255,199,128,128,128,81,99,181,242,176,190,249,202,255,255,128,
    1,129,232,253,214,197,242,196,255,255,128,99,121,210,250,201,198,255,202,128,128,128,
    23,91,163,242,170,187,247,210,255,255,128,1,200,246,255,234,255,128,128,128,128,128,
    109,178,241,255,231,245,255,255,128,128,128,44,130,201,253,205,192,255,255,128,128,128,
    1,132,239,251,219,209,255,165,128,128,128,94,136,225,251,218,190,255,255,128,128,128,
    22,100,174,245,186,161,255,199,128,128,128,1,182,249,255,232,235,128,128,128,128,128,
    124,143,241,255,227,234,128,128,128,128,128,35,77,181,251,193,211,255,205,128,128,128,
    1,157,247,255,236,231,255,255,128,128,128,121,141,235,255,225,227,255,255,128,128,128,
    45,99,188,251,195,217,255,224,128,128,128,1,1,251,255,213,255,128,128,128,128,128,
    203,1,248,255,255,128,128,128,128,128,128,137,1,177,255,224,255,128,128,128,128,128,
    253,9,248,251,207,208,255,192,128,128,128,175,13,224,243,193,185,249,198,255,255,128,
    73,17,171,221,161,179,236,167,255,234,128,1,95,247,253,212,183,255,255,128,128,128,
    239,90,244,250,211,209,255,255,128,128,128,155,77,195,248,188,195,255,255,128,128,128,
    1,24,239,251,218,219,255,205,128,128,128,201,51,219,255,196,186,128,128,128,128,128,
    69,46,190,239,201,218,255,228,128,128,128,1,191,251,255,255,128,128,128,128,128,128,
    223,165,249,255,213,255,128,128,128,128,128,141,124,248,255,255,128,128,128,128,128,128,
    1,16,248,255,255,128,128,128,128,128,128,190,36,230,255,236,255,128,128,128,128,128,
    149,1,255,128,128,128,128,128,128,128,128,1,226,255,128,128,128,128,128,128,128,128,
    247,192,255,128,128,128,128,128,128,128,128,240,128,255,128,128,128,128,128,128,128,128,
    1,134,252,255,255,128,128,128,128,128,128,213,62,250,255,255,128,128,128,128,128,128,
    55,93,255,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,
    128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,
    202,24,213,235,186,191,220,160,240,175,255,126,38,182,232,169,184,228,174,255,187,128,
    61,46,138,219,151,178,240,170,255,216,128,1,112,230,250,199,191,247,159,255,255,128,
    166,109,228,252,211,215,255,174,128,128,128,39,77,162,232,172,180,245,178,255,255,128,
    1,52,220,246,198,199,249,220,255,255,128,124,74,191,243,183,193,250,221,255,255,128,
    24,71,130,219,154,170,243,182,255,255,128,1,182,225,249,219,240,255,224,128,128,128,
    149,150,226,252,216,205,255,171,128,128,128,28,108,170,242,183,194,254,223,255,255,128,
    1,81,230,252,204,203,255,192,128,128,128,123,102,209,247,188,196,255,233,128,128,128,
    20,95,153,243,164,173,255,203,128,128,128,1,222,248,255,216,213,128,128,128,128,128,
    168,175,246,252,235,205,255,255,128,128,128,47,116,215,255,211,212,255,255,128,128,128,
    1,121,236,253,212,214,255,255,128,128,128,141,84,213,252,201,202,255,219,128,128,128,
    42,80,160,240,162,185,255,205,128,128,128,1,1,255,128,128,128,128,128,128,128,128,
    244,1,255,128,128,128,128,128,128,128,128,238,1,255,128,128,128,128,128,128,128,128
  );
  KCoeffsUpdate: array[0..1055] of Byte = (
    255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
    255,255,255,255,255,255,255,255,255,255,255,176,246,255,255,255,255,255,255,255,255,255,
    223,241,252,255,255,255,255,255,255,255,255,249,253,253,255,255,255,255,255,255,255,255,
    255,244,252,255,255,255,255,255,255,255,255,234,254,254,255,255,255,255,255,255,255,255,
    253,255,255,255,255,255,255,255,255,255,255,255,246,254,255,255,255,255,255,255,255,255,
    239,253,254,255,255,255,255,255,255,255,255,254,255,254,255,255,255,255,255,255,255,255,
    255,248,254,255,255,255,255,255,255,255,255,251,255,254,255,255,255,255,255,255,255,255,
    255,255,255,255,255,255,255,255,255,255,255,255,253,254,255,255,255,255,255,255,255,255,
    251,254,254,255,255,255,255,255,255,255,255,254,255,254,255,255,255,255,255,255,255,255,
    255,254,253,255,254,255,255,255,255,255,255,250,255,254,255,254,255,255,255,255,255,255,
    254,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
    255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
    217,255,255,255,255,255,255,255,255,255,255,225,252,241,253,255,255,254,255,255,255,255,
    234,250,241,250,253,255,253,254,255,255,255,255,254,255,255,255,255,255,255,255,255,255,
    223,254,254,255,255,255,255,255,255,255,255,238,253,254,254,255,255,255,255,255,255,255,
    255,248,254,255,255,255,255,255,255,255,255,249,254,255,255,255,255,255,255,255,255,255,
    255,255,255,255,255,255,255,255,255,255,255,255,253,255,255,255,255,255,255,255,255,255,
    247,254,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
    255,253,254,255,255,255,255,255,255,255,255,252,255,255,255,255,255,255,255,255,255,255,
    255,255,255,255,255,255,255,255,255,255,255,255,254,254,255,255,255,255,255,255,255,255,
    253,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
    255,254,253,255,255,255,255,255,255,255,255,250,255,255,255,255,255,255,255,255,255,255,
    254,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
    255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
    186,251,250,255,255,255,255,255,255,255,255,234,251,244,254,255,255,255,255,255,255,255,
    251,251,243,253,254,255,254,255,255,255,255,255,253,254,255,255,255,255,255,255,255,255,
    236,253,254,255,255,255,255,255,255,255,255,251,253,253,254,254,255,255,255,255,255,255,
    255,254,254,255,255,255,255,255,255,255,255,254,254,254,255,255,255,255,255,255,255,255,
    255,255,255,255,255,255,255,255,255,255,255,255,254,255,255,255,255,255,255,255,255,255,
    254,254,255,255,255,255,255,255,255,255,255,254,255,255,255,255,255,255,255,255,255,255,
    255,255,255,255,255,255,255,255,255,255,255,254,255,255,255,255,255,255,255,255,255,255,
    255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
    255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
    255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
    255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
    255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
    248,255,255,255,255,255,255,255,255,255,255,250,254,252,254,255,255,255,255,255,255,255,
    248,254,249,253,255,255,255,255,255,255,255,255,253,253,255,255,255,255,255,255,255,255,
    246,253,253,255,255,255,255,255,255,255,255,252,254,251,254,254,255,255,255,255,255,255,
    255,254,252,255,255,255,255,255,255,255,255,248,254,253,255,255,255,255,255,255,255,255,
    253,255,254,254,255,255,255,255,255,255,255,255,251,254,255,255,255,255,255,255,255,255,
    245,251,254,255,255,255,255,255,255,255,255,253,253,254,255,255,255,255,255,255,255,255,
    255,251,253,255,255,255,255,255,255,255,255,252,253,254,255,255,255,255,255,255,255,255,
    255,254,255,255,255,255,255,255,255,255,255,255,252,255,255,255,255,255,255,255,255,255,
    249,255,254,255,255,255,255,255,255,255,255,255,255,254,255,255,255,255,255,255,255,255,
    255,255,253,255,255,255,255,255,255,255,255,250,255,255,255,255,255,255,255,255,255,255,
    255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
    254,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255
  );
  KBModesProba: array[0..899] of Byte = (
    231,120,48,89,115,113,120,152,112,152,179,64,126,170,118,46,70,95,175,69,143,80,
    85,82,72,155,103,56,58,10,171,218,189,17,13,152,114,26,17,163,44,195,21,10,
    173,121,24,80,195,26,62,44,64,85,144,71,10,38,171,213,144,34,26,170,46,55,
    19,136,160,33,206,71,63,20,8,114,114,208,12,9,226,81,40,11,96,182,84,29,
    16,36,134,183,89,137,98,101,106,165,148,72,187,100,130,157,111,32,75,80,66,102,
    167,99,74,62,40,234,128,41,53,9,178,241,141,26,8,107,74,43,26,146,73,166,
    49,23,157,65,38,105,160,51,52,31,115,128,104,79,12,27,217,255,87,17,7,87,
    68,71,44,114,51,15,186,23,47,41,14,110,182,183,21,17,194,66,45,25,102,197,
    189,23,18,22,88,88,147,150,42,46,45,196,205,43,97,183,117,85,38,35,179,61,
    39,53,200,87,26,21,43,232,171,56,34,51,104,114,102,29,93,77,39,28,85,171,
    58,165,90,98,64,34,22,116,206,23,34,43,166,73,107,54,32,26,51,1,81,43,
    31,68,25,106,22,64,171,36,225,114,34,19,21,102,132,188,16,76,124,62,18,78,
    95,85,57,50,48,51,193,101,35,159,215,111,89,46,111,60,148,31,172,219,228,21,
    18,111,112,113,77,85,179,255,38,120,114,40,42,1,196,245,209,10,25,109,88,43,
    29,140,166,213,37,43,154,61,63,30,155,67,45,68,1,209,100,80,8,43,154,1,
    51,26,71,142,78,78,16,255,128,34,197,171,41,40,5,102,211,183,4,1,221,51,
    50,17,168,209,192,23,25,82,138,31,36,171,27,166,38,44,229,67,87,58,169,82,
    115,26,59,179,63,59,90,180,59,166,93,73,154,40,40,21,116,143,209,34,39,175,
    47,15,16,183,34,223,49,45,183,46,17,33,183,6,98,15,32,183,57,46,22,24,
    128,1,54,17,37,65,32,73,115,28,128,23,128,205,40,3,9,115,51,192,18,6,
    223,87,37,9,115,59,77,64,21,47,104,55,44,218,9,54,53,130,226,64,90,70,
    205,40,41,23,26,57,54,57,112,184,5,41,38,166,213,30,34,26,133,152,116,10,
    32,134,39,19,53,221,26,114,32,73,255,31,9,65,234,2,15,1,118,73,75,32,
    12,51,192,255,160,43,51,88,31,35,67,102,85,55,186,85,56,21,23,111,59,205,
    45,37,192,55,38,70,124,73,102,1,34,98,125,98,42,88,104,85,117,175,82,95,
    84,53,89,128,100,113,101,45,75,79,123,47,51,128,81,171,1,57,17,5,71,102,
    57,53,41,49,38,33,13,121,57,73,26,1,85,41,10,67,138,77,110,90,47,114,
    115,21,2,10,102,255,166,23,6,101,29,16,10,85,128,101,196,26,57,18,10,102,
    102,213,34,20,43,117,20,15,36,163,128,68,1,26,102,61,71,37,34,53,31,243,
    192,69,60,71,38,73,119,28,222,37,68,45,128,34,1,47,11,245,171,62,17,19,
    70,146,85,55,62,70,37,43,37,154,100,163,85,160,1,63,9,92,136,28,64,32,
    201,85,75,15,9,9,64,255,184,119,16,86,6,28,5,64,255,25,248,1,56,8,
    17,132,137,255,55,116,128,58,15,20,82,135,57,26,121,40,164,50,31,137,154,133,
    25,35,218,51,103,44,131,131,123,31,6,158,86,40,64,135,148,224,45,183,128,22,
    26,17,131,240,154,14,1,209,45,16,21,91,64,222,7,1,197,56,21,39,155,60,
    138,23,102,213,83,12,13,54,192,255,68,47,28,85,26,85,85,128,128,32,146,171,
    18,11,7,63,144,171,4,4,246,35,27,10,146,174,171,12,26,128,190,80,35,99,
    180,80,126,54,45,85,126,47,87,176,51,41,20,32,101,75,128,139,118,146,116,128,
    85,56,41,15,176,236,85,37,9,62,71,30,17,119,118,255,17,18,138,101,38,60,
    138,55,70,43,26,142,146,36,19,30,171,255,97,27,20,138,45,61,62,219,1,81,
    188,64,32,41,20,117,151,142,20,21,163,112,19,12,61,195,128,48,4,24
  );
  KDcTable: array[0..127] of Byte = (
    4,5,6,7,8,9,10,10,11,12,13,14,15,16,17,17,18,19,20,20,21,21,
    22,22,23,23,24,25,25,26,27,28,29,30,31,32,33,34,35,36,37,37,38,39,
    40,41,42,43,44,45,46,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,
    61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,76,77,78,79,80,81,
    82,83,84,85,86,87,88,89,91,93,95,96,98,100,101,102,104,106,108,110,112,114,
    116,118,122,124,126,128,130,132,134,136,138,140,143,145,148,151,154,157
  );
  KAcTable: array[0..127] of Word = (
    4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,
    26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,
    48,49,50,51,52,53,54,55,56,57,58,60,62,64,66,68,70,72,74,76,78,80,
    82,84,86,88,90,92,94,96,98,100,102,104,106,108,110,112,114,116,119,122,125,128,
    131,134,137,140,143,146,149,152,155,158,161,164,167,170,173,177,181,185,189,193,197,201,
    205,209,213,217,221,225,229,234,239,245,249,254,259,264,269,274,279,284
  );
  {$ENDREGION}

type
  { RFC 6386 §7 boolean (arithmetic) decoder. }
  TBoolDec = record
    Buf: PByte; BufEnd: PByte;
    Range: Cardinal; Value: Cardinal; BitCount: Integer;
  end;

  TMB = record nz, nz_dc: Byte; end;                 // top/left nz context
  TTopSamp = record y: array[0..15] of Byte; u, v: array[0..7] of Byte; end;
  TFInfo = record f_limit, f_ilevel, f_inner, hev_thresh: Integer; end;

  TMBData = record
    coeffs: array[0..383] of SmallInt;
    imodes: array[0..15] of Byte;
    uvmode: Byte;
    is_i4x4: Boolean;
    skip: Byte;
    segment: Integer;
    non_zero_y, non_zero_uv: Cardinal;
  end;

  PDec = ^TDec;
  TDec = record
    br: TBoolDec;                        // partition 0 (header + intra modes)
    parts: array[0..7] of TBoolDec;      // token partitions
    nPartsM1: Integer;

    W, H: Integer;                       // display dimensions
    mb_w, mb_h: Integer;

    // segmentation header
    useSeg, updateMap, absDelta: Boolean;
    segQuant, segFilter: array[0..3] of Integer;
    segProb: array[0..2] of Byte;

    // filter header
    fSimple: Boolean; fLevel, fSharp: Integer;
    useLfDelta: Boolean; refLf, modeLf: array[0..3] of Integer;
    filterType: Integer;                 // 0 off, 1 simple, 2 complex

    useSkipProba: Boolean; skipP: Byte;

    // coefficient probabilities  [type][band][ctx][proba]
    Bands: array[0..3, 0..7, 0..2, 0..10] of Byte;

    // dequant per segment: [seg] -> y1(dc,ac) y2(dc,ac) uv(dc,ac)
    dqY1, dqY2, dqUV: array[0..3, 0..1] of Integer;

    // planes (reconstructed, then filtered)
    Ybuf, Ubuf, Vbuf: TBytes;
    sY, sUV: Integer;

    top: array of TMB; leftMB: TMB;      // nz context (top persists, left per-row)
    intraT: array of Byte; intraL: array[0..3] of Byte;
    yuvt: array of TTopSamp;
    work: array[0..YUV_SIZE - 1] of Byte;

    // per-MB filter source info (whole frame)
    fSegA, fI4A, fSkipA: array of Byte;
    fstrength: array[0..3, 0..1] of TFInfo;

    mbrow: array of TMBData;             // current row's parsed MB data
    pRGBA: PByte;                        // output buffer (during EmitFancyRGB)
  end;

{ ---- arithmetic right shift (FPC 'shr' is logical) --------------------- }
function ASR(v, s: Integer): Integer; inline;
begin
  if v >= 0 then Result := v shr s
  else Result := not((not v) shr s);
end;

function Clip8(v: Integer): Integer; inline;
begin
  if v < 0 then Result := 0 else if v > 255 then Result := 255 else Result := v;
end;

function Clip1(v: Integer): Integer; inline;       // -> [0,255]
begin
  if v < 0 then Result := 0 else if v > 255 then Result := 255 else Result := v;
end;

function SClip1(v: Integer): Integer; inline;      // -> [-128,127]
begin
  if v < -128 then Result := -128 else if v > 127 then Result := 127 else Result := v;
end;

function SClip2(v: Integer): Integer; inline;      // -> [-16,15]
begin
  if v < -16 then Result := -16 else if v > 15 then Result := 15 else Result := v;
end;

{ ---- boolean decoder --------------------------------------------------- }

procedure BD_Init(var d: TBoolDec; Buf: PByte; Size: Integer);
var b0, b1: Cardinal;
begin
  d.Buf := Buf; d.BufEnd := Buf + Size;
  if Size >= 1 then b0 := Buf[0] else b0 := 0;
  if Size >= 2 then b1 := Buf[1] else b1 := 0;
  d.Value := (b0 shl 8) or b1;
  d.Buf := d.Buf + 2;
  d.Range := 255; d.BitCount := 0;
end;

function BD_GetBit(var d: TBoolDec; prob: Integer): Integer;
var split, bigSplit: Cardinal; bit: Integer;
begin
  split := 1 + (((d.Range - 1) * Cardinal(prob)) shr 8);
  bigSplit := split shl 8;
  if d.Value >= bigSplit then
  begin
    bit := 1; d.Range := d.Range - split; d.Value := d.Value - bigSplit;
  end
  else begin bit := 0; d.Range := split; end;
  while d.Range < 128 do
  begin
    d.Value := d.Value shl 1; d.Range := d.Range shl 1;
    Inc(d.BitCount);
    if d.BitCount = 8 then
    begin
      d.BitCount := 0;
      if d.Buf < d.BufEnd then d.Value := d.Value or d.Buf^;
      Inc(d.Buf);
    end;
  end;
  Result := bit;
end;

function BD_GetLit(var d: TBoolDec; n: Integer): Integer;  // n-bit literal, MSB first (prob 128)
var v, i: Integer;
begin
  v := 0;
  for i := 1 to n do v := (v shl 1) or BD_GetBit(d, 128);
  Result := v;
end;

function BD_GetSigned(var d: TBoolDec; v: Integer): Integer;   // magnitude + sign flag
begin
  if BD_GetBit(d, 128) <> 0 then Result := -v else Result := v;
end;

function BD_GetSignedValue(var d: TBoolDec; n: Integer): Integer;
var mag: Integer;
begin
  mag := BD_GetLit(d, n);
  if BD_GetBit(d, 128) <> 0 then Result := -mag else Result := mag;
end;

{ ---- transforms (§14) -------------------------------------------------- }

function Mul1(a: Integer): Integer; inline;
begin Result := a + ASR(a * 20091, 16); end;
function Mul2(a: Integer): Integer; inline;
begin Result := ASR(a * 35468, 16); end;

procedure StoreOne(dst: PByte; x, y, v: Integer); inline;
var p: PByte;
begin
  p := dst + x + y * BPS;
  p^ := Clip8(p^ + ASR(v, 3));
end;

procedure IDCT4x4(inp: PSmallInt; dst: PByte);      // TransformOne_C
var Tv: array[0..15] of Integer; i, a, b, c, d, dc: Integer;
begin
  for i := 0 to 3 do
  begin
    a := inp[i] + inp[8 + i];
    b := inp[i] - inp[8 + i];
    c := Mul2(inp[4 + i]) - Mul1(inp[12 + i]);
    d := Mul1(inp[4 + i]) + Mul2(inp[12 + i]);
    Tv[i * 4 + 0] := a + d; Tv[i * 4 + 1] := b + c;
    Tv[i * 4 + 2] := b - c; Tv[i * 4 + 3] := a - d;
  end;
  for i := 0 to 3 do
  begin
    dc := Tv[i] + 4;
    a := dc + Tv[8 + i]; b := dc - Tv[8 + i];
    c := Mul2(Tv[4 + i]) - Mul1(Tv[12 + i]);
    d := Mul1(Tv[4 + i]) + Mul2(Tv[12 + i]);
    StoreOne(dst, 0, i, a + d); StoreOne(dst, 1, i, b + c);
    StoreOne(dst, 2, i, b - c); StoreOne(dst, 3, i, a - d);
  end;
end;

procedure Store2(dst: PByte; y, dc, dd, cc: Integer); inline;
begin
  StoreOne(dst, 0, y, dc + dd); StoreOne(dst, 1, y, dc + cc);
  StoreOne(dst, 2, y, dc - cc); StoreOne(dst, 3, y, dc - dd);
end;

procedure TransformAC3(inp: PSmallInt; dst: PByte);
var a, c4, d4, c1, d1: Integer;
begin
  a := inp[0] + 4;
  c4 := Mul2(inp[4]); d4 := Mul1(inp[4]);
  c1 := Mul2(inp[1]); d1 := Mul1(inp[1]);
  Store2(dst, 0, a + d4, d1, c1);
  Store2(dst, 1, a + c4, d1, c1);
  Store2(dst, 2, a - c4, d1, c1);
  Store2(dst, 3, a - d4, d1, c1);
end;

procedure TransformDC(inp: PSmallInt; dst: PByte);
var dc, i, j: Integer;
begin
  dc := inp[0] + 4;
  for j := 0 to 3 do for i := 0 to 3 do StoreOne(dst, i, j, dc);
end;

procedure TransformOneTwo(inp: PSmallInt; dst: PByte; doTwo: Boolean);
begin
  IDCT4x4(inp, dst);
  if doTwo then IDCT4x4(inp + 16, dst + 4);
end;

procedure TransformUV(inp: PSmallInt; dst: PByte);
begin
  TransformOneTwo(inp, dst, True);
  TransformOneTwo(inp + 2 * 16, dst + 4 * BPS, True);
end;

procedure TransformDCUV(inp: PSmallInt; dst: PByte);
begin
  if inp[0 * 16] <> 0 then TransformDC(inp + 0 * 16, dst);
  if inp[1 * 16] <> 0 then TransformDC(inp + 1 * 16, dst + 4);
  if inp[2 * 16] <> 0 then TransformDC(inp + 2 * 16, dst + 4 * BPS);
  if inp[3 * 16] <> 0 then TransformDC(inp + 3 * 16, dst + 4 * BPS + 4);
end;

procedure TransformWHT(inp: PSmallInt; outp: PSmallInt);   // §14.3
var tmp: array[0..15] of Integer; i, a0, a1, a2, a3, dc: Integer; o: PSmallInt;
begin
  for i := 0 to 3 do
  begin
    a0 := inp[0 + i] + inp[12 + i];
    a1 := inp[4 + i] + inp[8 + i];
    a2 := inp[4 + i] - inp[8 + i];
    a3 := inp[0 + i] - inp[12 + i];
    tmp[0 + i] := a0 + a1; tmp[8 + i] := a0 - a1;
    tmp[4 + i] := a3 + a2; tmp[12 + i] := a3 - a2;
  end;
  o := outp;
  for i := 0 to 3 do
  begin
    dc := tmp[0 + i * 4] + 3;
    a0 := dc + tmp[3 + i * 4];
    a1 := tmp[1 + i * 4] + tmp[2 + i * 4];
    a2 := tmp[1 + i * 4] - tmp[2 + i * 4];
    a3 := dc - tmp[3 + i * 4];
    o[0]  := ASR(a0 + a1, 3);
    o[16] := ASR(a3 + a2, 3);
    o[32] := ASR(a0 - a1, 3);
    o[48] := ASR(a3 - a2, 3);
    o := o + 64;
  end;
end;

{ ---- intra prediction (§12) -------------------------------------------- }

procedure TrueMotion(dst: PByte; size: Integer);
var top: PByte; tl, x, y: Integer;
begin
  top := dst - BPS;
  tl := (top - 1)^;
  for y := 0 to size - 1 do
  begin
    for x := 0 to size - 1 do
      (dst + x)^ := Clip1(top[x] + (dst - 1)^ - tl);
    dst := dst + BPS;
  end;
end;

procedure FillBlock(dst: PByte; v, size: Integer);
var i, j: Integer;
begin
  for j := 0 to size - 1 do
    for i := 0 to size - 1 do (dst + i + j * BPS)^ := Byte(v);
end;

// 16x16
procedure DC16(dst: PByte); var s, j: Integer;
begin s := 16; for j := 0 to 15 do s := s + (dst - 1 + j * BPS)^ + (dst + j - BPS)^; FillBlock(dst, s shr 5, 16); end;
procedure DC16NoTop(dst: PByte); var s, j: Integer;
begin s := 8; for j := 0 to 15 do s := s + (dst - 1 + j * BPS)^; FillBlock(dst, s shr 4, 16); end;
procedure DC16NoLeft(dst: PByte); var s, i: Integer;
begin s := 8; for i := 0 to 15 do s := s + (dst + i - BPS)^; FillBlock(dst, s shr 4, 16); end;
procedure DC16NoTopLeft(dst: PByte); begin FillBlock(dst, $80, 16); end;
procedure VE16(dst: PByte); var i, j: Integer;
begin for j := 0 to 15 do for i := 0 to 15 do (dst + i + j * BPS)^ := (dst + i - BPS)^; end;
procedure HE16(dst: PByte); var i, j: Integer;
begin for j := 0 to 15 do for i := 0 to 15 do (dst + i + j * BPS)^ := (dst - 1 + j * BPS)^; end;
procedure TM16(dst: PByte); begin TrueMotion(dst, 16); end;

// chroma 8x8
procedure DC8(dst: PByte); var s, i: Integer;
begin s := 8; for i := 0 to 7 do s := s + (dst + i - BPS)^ + (dst - 1 + i * BPS)^; FillBlock(dst, s shr 4, 8); end;
procedure DC8NoLeft(dst: PByte); var s, i: Integer;
begin s := 4; for i := 0 to 7 do s := s + (dst + i - BPS)^; FillBlock(dst, s shr 3, 8); end;
procedure DC8NoTop(dst: PByte); var s, i: Integer;
begin s := 4; for i := 0 to 7 do s := s + (dst - 1 + i * BPS)^; FillBlock(dst, s shr 3, 8); end;
procedure DC8NoTopLeft(dst: PByte); begin FillBlock(dst, $80, 8); end;
procedure VE8(dst: PByte); var i, j: Integer;
begin for j := 0 to 7 do for i := 0 to 7 do (dst + i + j * BPS)^ := (dst + i - BPS)^; end;
procedure HE8(dst: PByte); var i, j: Integer;
begin for j := 0 to 7 do for i := 0 to 7 do (dst + i + j * BPS)^ := (dst - 1 + j * BPS)^; end;
procedure TM8(dst: PByte); begin TrueMotion(dst, 8); end;

// 4x4 helpers
function AVG3(a, b, c: Integer): Integer; inline; begin Result := (a + 2 * b + c + 2) shr 2; end;
function AVG2(a, b: Integer): Integer; inline; begin Result := (a + b + 1) shr 1; end;
procedure PutD(dst: PByte; x, y, v: Integer); inline; begin (dst + x + y * BPS)^ := Byte(v); end;

procedure DC4(dst: PByte); var dc, i: Integer;
begin
  dc := 4; for i := 0 to 3 do dc := dc + (dst + i - BPS)^ + (dst - 1 + i * BPS)^;
  dc := dc shr 3; FillBlock(dst, dc, 4);
end;
procedure TM4(dst: PByte); begin TrueMotion(dst, 4); end;
procedure VE4(dst: PByte);
var top: PByte; v0, v1, v2, v3, i: Integer;
begin
  top := dst - BPS;
  v0 := AVG3((top - 1)^, top[0], top[1]);
  v1 := AVG3(top[0], top[1], top[2]);
  v2 := AVG3(top[1], top[2], top[3]);
  v3 := AVG3(top[2], top[3], top[4]);
  for i := 0 to 3 do
  begin
    PutD(dst, 0, i, v0); PutD(dst, 1, i, v1); PutD(dst, 2, i, v2); PutD(dst, 3, i, v3);
  end;
end;
procedure HE4(dst: PByte);
var a, b, c, d, e: Integer;
begin
  a := (dst - 1 - BPS)^; b := (dst - 1)^; c := (dst - 1 + BPS)^;
  d := (dst - 1 + 2 * BPS)^; e := (dst - 1 + 3 * BPS)^;
  PutD(dst, 0, 0, AVG3(a, b, c)); PutD(dst, 1, 0, AVG3(a, b, c)); PutD(dst, 2, 0, AVG3(a, b, c)); PutD(dst, 3, 0, AVG3(a, b, c));
  PutD(dst, 0, 1, AVG3(b, c, d)); PutD(dst, 1, 1, AVG3(b, c, d)); PutD(dst, 2, 1, AVG3(b, c, d)); PutD(dst, 3, 1, AVG3(b, c, d));
  PutD(dst, 0, 2, AVG3(c, d, e)); PutD(dst, 1, 2, AVG3(c, d, e)); PutD(dst, 2, 2, AVG3(c, d, e)); PutD(dst, 3, 2, AVG3(c, d, e));
  PutD(dst, 0, 3, AVG3(d, e, e)); PutD(dst, 1, 3, AVG3(d, e, e)); PutD(dst, 2, 3, AVG3(d, e, e)); PutD(dst, 3, 3, AVG3(d, e, e));
end;
procedure RD4(dst: PByte);
var i, j, k, l, x, a, b, c, d: Integer;
begin
  i := (dst - 1 + 0 * BPS)^; j := (dst - 1 + 1 * BPS)^; k := (dst - 1 + 2 * BPS)^; l := (dst - 1 + 3 * BPS)^;
  x := (dst - 1 - BPS)^; a := (dst + 0 - BPS)^; b := (dst + 1 - BPS)^; c := (dst + 2 - BPS)^; d := (dst + 3 - BPS)^;
  PutD(dst, 0, 3, AVG3(j, k, l));
  PutD(dst, 1, 3, AVG3(i, j, k)); PutD(dst, 0, 2, AVG3(i, j, k));
  PutD(dst, 2, 3, AVG3(x, i, j)); PutD(dst, 1, 2, AVG3(x, i, j)); PutD(dst, 0, 1, AVG3(x, i, j));
  PutD(dst, 3, 3, AVG3(a, x, i)); PutD(dst, 2, 2, AVG3(a, x, i)); PutD(dst, 1, 1, AVG3(a, x, i)); PutD(dst, 0, 0, AVG3(a, x, i));
  PutD(dst, 3, 2, AVG3(b, a, x)); PutD(dst, 2, 1, AVG3(b, a, x)); PutD(dst, 1, 0, AVG3(b, a, x));
  PutD(dst, 3, 1, AVG3(c, b, a)); PutD(dst, 2, 0, AVG3(c, b, a));
  PutD(dst, 3, 0, AVG3(d, c, b));
end;
procedure LD4(dst: PByte);
var a, b, c, d, e, f, g, h: Integer;
begin
  a := (dst + 0 - BPS)^; b := (dst + 1 - BPS)^; c := (dst + 2 - BPS)^; d := (dst + 3 - BPS)^;
  e := (dst + 4 - BPS)^; f := (dst + 5 - BPS)^; g := (dst + 6 - BPS)^; h := (dst + 7 - BPS)^;
  PutD(dst, 0, 0, AVG3(a, b, c));
  PutD(dst, 1, 0, AVG3(b, c, d)); PutD(dst, 0, 1, AVG3(b, c, d));
  PutD(dst, 2, 0, AVG3(c, d, e)); PutD(dst, 1, 1, AVG3(c, d, e)); PutD(dst, 0, 2, AVG3(c, d, e));
  PutD(dst, 3, 0, AVG3(d, e, f)); PutD(dst, 2, 1, AVG3(d, e, f)); PutD(dst, 1, 2, AVG3(d, e, f)); PutD(dst, 0, 3, AVG3(d, e, f));
  PutD(dst, 3, 1, AVG3(e, f, g)); PutD(dst, 2, 2, AVG3(e, f, g)); PutD(dst, 1, 3, AVG3(e, f, g));
  PutD(dst, 3, 2, AVG3(f, g, h)); PutD(dst, 2, 3, AVG3(f, g, h));
  PutD(dst, 3, 3, AVG3(g, h, h));
end;
procedure VR4(dst: PByte);
var i, j, k, x, a, b, c, d: Integer;
begin
  i := (dst - 1 + 0 * BPS)^; j := (dst - 1 + 1 * BPS)^; k := (dst - 1 + 2 * BPS)^;
  x := (dst - 1 - BPS)^; a := (dst + 0 - BPS)^; b := (dst + 1 - BPS)^; c := (dst + 2 - BPS)^; d := (dst + 3 - BPS)^;
  PutD(dst, 0, 0, AVG2(x, a)); PutD(dst, 1, 2, AVG2(x, a));
  PutD(dst, 1, 0, AVG2(a, b)); PutD(dst, 2, 2, AVG2(a, b));
  PutD(dst, 2, 0, AVG2(b, c)); PutD(dst, 3, 2, AVG2(b, c));
  PutD(dst, 3, 0, AVG2(c, d));
  PutD(dst, 0, 3, AVG3(k, j, i));
  PutD(dst, 0, 2, AVG3(j, i, x));
  PutD(dst, 0, 1, AVG3(i, x, a)); PutD(dst, 1, 3, AVG3(i, x, a));
  PutD(dst, 1, 1, AVG3(x, a, b)); PutD(dst, 2, 3, AVG3(x, a, b));
  PutD(dst, 2, 1, AVG3(a, b, c)); PutD(dst, 3, 3, AVG3(a, b, c));
  PutD(dst, 3, 1, AVG3(b, c, d));
end;
procedure VL4(dst: PByte);
var a, b, c, d, e, f, g, h: Integer;
begin
  a := (dst + 0 - BPS)^; b := (dst + 1 - BPS)^; c := (dst + 2 - BPS)^; d := (dst + 3 - BPS)^;
  e := (dst + 4 - BPS)^; f := (dst + 5 - BPS)^; g := (dst + 6 - BPS)^; h := (dst + 7 - BPS)^;
  PutD(dst, 0, 0, AVG2(a, b));
  PutD(dst, 1, 0, AVG2(b, c)); PutD(dst, 0, 2, AVG2(b, c));
  PutD(dst, 2, 0, AVG2(c, d)); PutD(dst, 1, 2, AVG2(c, d));
  PutD(dst, 3, 0, AVG2(d, e)); PutD(dst, 2, 2, AVG2(d, e));
  PutD(dst, 0, 1, AVG3(a, b, c));
  PutD(dst, 1, 1, AVG3(b, c, d)); PutD(dst, 0, 3, AVG3(b, c, d));
  PutD(dst, 2, 1, AVG3(c, d, e)); PutD(dst, 1, 3, AVG3(c, d, e));
  PutD(dst, 3, 1, AVG3(d, e, f)); PutD(dst, 2, 3, AVG3(d, e, f));
  PutD(dst, 3, 2, AVG3(e, f, g));
  PutD(dst, 3, 3, AVG3(f, g, h));
end;
procedure HU4(dst: PByte);
var i, j, k, l: Integer;
begin
  i := (dst - 1 + 0 * BPS)^; j := (dst - 1 + 1 * BPS)^; k := (dst - 1 + 2 * BPS)^; l := (dst - 1 + 3 * BPS)^;
  PutD(dst, 0, 0, AVG2(i, j));
  PutD(dst, 2, 0, AVG2(j, k)); PutD(dst, 0, 1, AVG2(j, k));
  PutD(dst, 2, 1, AVG2(k, l)); PutD(dst, 0, 2, AVG2(k, l));
  PutD(dst, 1, 0, AVG3(i, j, k));
  PutD(dst, 3, 0, AVG3(j, k, l)); PutD(dst, 1, 1, AVG3(j, k, l));
  PutD(dst, 3, 1, AVG3(k, l, l)); PutD(dst, 1, 2, AVG3(k, l, l));
  PutD(dst, 3, 2, l); PutD(dst, 2, 2, l); PutD(dst, 0, 3, l);
  PutD(dst, 1, 3, l); PutD(dst, 2, 3, l); PutD(dst, 3, 3, l);
end;
procedure HD4(dst: PByte);
var i, j, k, l, x, a, b, c: Integer;
begin
  i := (dst - 1 + 0 * BPS)^; j := (dst - 1 + 1 * BPS)^; k := (dst - 1 + 2 * BPS)^; l := (dst - 1 + 3 * BPS)^;
  x := (dst - 1 - BPS)^; a := (dst + 0 - BPS)^; b := (dst + 1 - BPS)^; c := (dst + 2 - BPS)^;
  PutD(dst, 0, 0, AVG2(i, x)); PutD(dst, 2, 1, AVG2(i, x));
  PutD(dst, 0, 1, AVG2(j, i)); PutD(dst, 2, 2, AVG2(j, i));
  PutD(dst, 0, 2, AVG2(k, j)); PutD(dst, 2, 3, AVG2(k, j));
  PutD(dst, 0, 3, AVG2(l, k));
  PutD(dst, 3, 0, AVG3(a, b, c));
  PutD(dst, 2, 0, AVG3(x, a, b));
  PutD(dst, 1, 0, AVG3(i, x, a)); PutD(dst, 3, 1, AVG3(i, x, a));
  PutD(dst, 1, 1, AVG3(j, i, x)); PutD(dst, 3, 2, AVG3(j, i, x));
  PutD(dst, 1, 2, AVG3(k, j, i)); PutD(dst, 3, 3, AVG3(k, j, i));
  PutD(dst, 1, 3, AVG3(l, k, j));
end;

procedure PredLuma4(mode: Integer; dst: PByte);
begin
  case mode of
    0: DC4(dst); 1: TM4(dst); 2: VE4(dst); 3: HE4(dst); 4: RD4(dst);
    5: VR4(dst); 6: LD4(dst); 7: VL4(dst); 8: HD4(dst); 9: HU4(dst);
  end;
end;

procedure PredLuma16(mode: Integer; dst: PByte);
begin
  case mode of
    0: DC16(dst); 1: TM16(dst); 2: VE16(dst); 3: HE16(dst);
    4: DC16NoTop(dst); 5: DC16NoLeft(dst); 6: DC16NoTopLeft(dst);
  end;
end;

procedure PredChroma8(mode: Integer; dst: PByte);
begin
  case mode of
    0: DC8(dst); 1: TM8(dst); 2: VE8(dst); 3: HE8(dst);
    4: DC8NoTop(dst); 5: DC8NoLeft(dst); 6: DC8NoTopLeft(dst);
  end;
end;

{ ---- in-loop deblocking filter (§15) ----------------------------------- }

function Hev(p: PByte; step, thresh: Integer): Boolean; inline;
var p1, p0, q0, q1: Integer;
begin
  p1 := (p - 2 * step)^; p0 := (p - step)^; q0 := p^; q1 := (p + step)^;
  Result := (Abs(p1 - p0) > thresh) or (Abs(q1 - q0) > thresh);
end;

function NeedsFilter(p: PByte; step, t: Integer): Boolean; inline;
var p1, p0, q0, q1: Integer;
begin
  p1 := (p - 2 * step)^; p0 := (p - step)^; q0 := p^; q1 := (p + step)^;
  Result := (4 * Abs(p0 - q0) + Abs(p1 - q1)) <= t;
end;

function NeedsFilter2(p: PByte; step, t, it: Integer): Boolean; inline;
var p3, p2, p1, p0, q0, q1, q2, q3: Integer;
begin
  p3 := (p - 4 * step)^; p2 := (p - 3 * step)^; p1 := (p - 2 * step)^;
  p0 := (p - step)^; q0 := p^;
  q1 := (p + step)^; q2 := (p + 2 * step)^; q3 := (p + 3 * step)^;
  if (4 * Abs(p0 - q0) + Abs(p1 - q1)) > t then Exit(False);
  Result := (Abs(p3 - p2) <= it) and (Abs(p2 - p1) <= it) and (Abs(p1 - p0) <= it)
        and (Abs(q3 - q2) <= it) and (Abs(q2 - q1) <= it) and (Abs(q1 - q0) <= it);
end;

procedure DoFilter2(p: PByte; step: Integer); inline;
var p1, p0, q0, q1, a, a1, a2: Integer;
begin
  p1 := (p - 2 * step)^; p0 := (p - step)^; q0 := p^; q1 := (p + step)^;
  a := 3 * (q0 - p0) + SClip1(p1 - q1);
  a1 := SClip2(ASR(a + 4, 3));
  a2 := SClip2(ASR(a + 3, 3));
  (p - step)^ := Clip1(p0 + a2);
  p^ := Clip1(q0 - a1);
end;

procedure DoFilter4(p: PByte; step: Integer); inline;
var p1, p0, q0, q1, a, a1, a2, a3: Integer;
begin
  p1 := (p - 2 * step)^; p0 := (p - step)^; q0 := p^; q1 := (p + step)^;
  a := 3 * (q0 - p0);
  a1 := SClip2(ASR(a + 4, 3));
  a2 := SClip2(ASR(a + 3, 3));
  a3 := ASR(a1 + 1, 1);
  (p - 2 * step)^ := Clip1(p1 + a3);
  (p - step)^ := Clip1(p0 + a2);
  p^ := Clip1(q0 - a1);
  (p + step)^ := Clip1(q1 - a3);
end;

procedure DoFilter6(p: PByte; step: Integer); inline;
var p2, p1, p0, q0, q1, q2, a, a1, a2, a3: Integer;
begin
  p2 := (p - 3 * step)^; p1 := (p - 2 * step)^; p0 := (p - step)^;
  q0 := p^; q1 := (p + step)^; q2 := (p + 2 * step)^;
  a := SClip1(3 * (q0 - p0) + SClip1(p1 - q1));
  a1 := ASR(27 * a + 63, 7);
  a2 := ASR(18 * a + 63, 7);
  a3 := ASR(9 * a + 63, 7);
  (p - 3 * step)^ := Clip1(p2 + a3);
  (p - 2 * step)^ := Clip1(p1 + a2);
  (p - step)^ := Clip1(p0 + a1);
  p^ := Clip1(q0 - a1);
  (p + step)^ := Clip1(q1 - a2);
  (p + 2 * step)^ := Clip1(q2 + (-a3));
end;

// simple filters
procedure SimpleVFilter16(p: PByte; stride, thresh: Integer);
var i, t2: Integer;
begin t2 := 2 * thresh + 1; for i := 0 to 15 do if NeedsFilter(p + i, stride, t2) then DoFilter2(p + i, stride); end;
procedure SimpleHFilter16(p: PByte; stride, thresh: Integer);
var i, t2: Integer;
begin t2 := 2 * thresh + 1; for i := 0 to 15 do if NeedsFilter(p + i * stride, 1, t2) then DoFilter2(p + i * stride, 1); end;
procedure SimpleVFilter16i(p: PByte; stride, thresh: Integer);
var k: Integer; q: PByte;
begin q := p; for k := 3 downto 1 do begin q := q + 4 * stride; SimpleVFilter16(q, stride, thresh); end; end;
procedure SimpleHFilter16i(p: PByte; stride, thresh: Integer);
var k: Integer; q: PByte;
begin q := p; for k := 3 downto 1 do begin q := q + 4; SimpleHFilter16(q, stride, thresh); end; end;

// complex filters
procedure FilterLoop26(p: PByte; hstride, vstride, size, thresh, ithresh, hevt: Integer);
var t2: Integer;
begin
  t2 := 2 * thresh + 1;
  while size > 0 do
  begin
    if NeedsFilter2(p, hstride, t2, ithresh) then
    begin
      if Hev(p, hstride, hevt) then DoFilter2(p, hstride) else DoFilter6(p, hstride);
    end;
    p := p + vstride; Dec(size);
  end;
end;

procedure FilterLoop24(p: PByte; hstride, vstride, size, thresh, ithresh, hevt: Integer);
var t2: Integer;
begin
  t2 := 2 * thresh + 1;
  while size > 0 do
  begin
    if NeedsFilter2(p, hstride, t2, ithresh) then
    begin
      if Hev(p, hstride, hevt) then DoFilter2(p, hstride) else DoFilter4(p, hstride);
    end;
    p := p + vstride; Dec(size);
  end;
end;

procedure VFilter16(p: PByte; stride, thresh, ithresh, hevt: Integer);
begin FilterLoop26(p, stride, 1, 16, thresh, ithresh, hevt); end;
procedure HFilter16(p: PByte; stride, thresh, ithresh, hevt: Integer);
begin FilterLoop26(p, 1, stride, 16, thresh, ithresh, hevt); end;
procedure VFilter16i(p: PByte; stride, thresh, ithresh, hevt: Integer);
var k: Integer; q: PByte;
begin q := p; for k := 3 downto 1 do begin q := q + 4 * stride; FilterLoop24(q, stride, 1, 16, thresh, ithresh, hevt); end; end;
procedure HFilter16i(p: PByte; stride, thresh, ithresh, hevt: Integer);
var k: Integer; q: PByte;
begin q := p; for k := 3 downto 1 do begin q := q + 4; FilterLoop24(q, 1, stride, 16, thresh, ithresh, hevt); end; end;
procedure VFilter8(u, v: PByte; stride, thresh, ithresh, hevt: Integer);
begin FilterLoop26(u, stride, 1, 8, thresh, ithresh, hevt); FilterLoop26(v, stride, 1, 8, thresh, ithresh, hevt); end;
procedure HFilter8(u, v: PByte; stride, thresh, ithresh, hevt: Integer);
begin FilterLoop26(u, 1, stride, 8, thresh, ithresh, hevt); FilterLoop26(v, 1, stride, 8, thresh, ithresh, hevt); end;
procedure VFilter8i(u, v: PByte; stride, thresh, ithresh, hevt: Integer);
begin FilterLoop24(u + 4 * stride, stride, 1, 8, thresh, ithresh, hevt); FilterLoop24(v + 4 * stride, stride, 1, 8, thresh, ithresh, hevt); end;
procedure HFilter8i(u, v: PByte; stride, thresh, ithresh, hevt: Integer);
begin FilterLoop24(u + 4, 1, stride, 8, thresh, ithresh, hevt); FilterLoop24(v + 4, 1, stride, 8, thresh, ithresh, hevt); end;

{ ---- header parsing ---------------------------------------------------- }

procedure ParseSegmentHeader(var d: TDec);
var s: Integer;
begin
  d.useSeg := BD_GetBit(d.br, 128) <> 0;
  if d.useSeg then
  begin
    d.updateMap := BD_GetBit(d.br, 128) <> 0;
    if BD_GetBit(d.br, 128) <> 0 then          // update data
    begin
      d.absDelta := BD_GetBit(d.br, 128) <> 0;
      for s := 0 to 3 do
        if BD_GetBit(d.br, 128) <> 0 then d.segQuant[s] := BD_GetSignedValue(d.br, 7)
        else d.segQuant[s] := 0;
      for s := 0 to 3 do
        if BD_GetBit(d.br, 128) <> 0 then d.segFilter[s] := BD_GetSignedValue(d.br, 6)
        else d.segFilter[s] := 0;
    end;
    if d.updateMap then
      for s := 0 to 2 do
        if BD_GetBit(d.br, 128) <> 0 then d.segProb[s] := BD_GetLit(d.br, 8)
        else d.segProb[s] := 255;
  end
  else d.updateMap := False;
end;

procedure ParseFilterHeader(var d: TDec);
var i: Integer;
begin
  d.fSimple := BD_GetBit(d.br, 128) <> 0;
  d.fLevel := BD_GetLit(d.br, 6);
  d.fSharp := BD_GetLit(d.br, 3);
  d.useLfDelta := BD_GetBit(d.br, 128) <> 0;
  if d.useLfDelta then
    if BD_GetBit(d.br, 128) <> 0 then
    begin
      for i := 0 to 3 do if BD_GetBit(d.br, 128) <> 0 then d.refLf[i] := BD_GetSignedValue(d.br, 6);
      for i := 0 to 3 do if BD_GetBit(d.br, 128) <> 0 then d.modeLf[i] := BD_GetSignedValue(d.br, 6);
    end;
  if d.fLevel = 0 then d.filterType := 0
  else if d.fSimple then d.filterType := 1
  else d.filterType := 2;
end;

function Clip127(v, M: Integer): Integer; inline;
begin if v < 0 then Result := 0 else if v > M then Result := M else Result := v; end;

procedure ParseQuant(var d: TDec);
var baseQ, dqy1dc, dqy2dc, dqy2ac, dquvdc, dquvac, i, q: Integer;
begin
  baseQ := BD_GetLit(d.br, 7);
  if BD_GetBit(d.br, 128) <> 0 then dqy1dc := BD_GetSignedValue(d.br, 4) else dqy1dc := 0;
  if BD_GetBit(d.br, 128) <> 0 then dqy2dc := BD_GetSignedValue(d.br, 4) else dqy2dc := 0;
  if BD_GetBit(d.br, 128) <> 0 then dqy2ac := BD_GetSignedValue(d.br, 4) else dqy2ac := 0;
  if BD_GetBit(d.br, 128) <> 0 then dquvdc := BD_GetSignedValue(d.br, 4) else dquvdc := 0;
  if BD_GetBit(d.br, 128) <> 0 then dquvac := BD_GetSignedValue(d.br, 4) else dquvac := 0;
  for i := 0 to 3 do
  begin
    if d.useSeg then
    begin
      q := d.segQuant[i];
      if not d.absDelta then q := q + baseQ;
    end
    else
    begin
      if i > 0 then
      begin
        d.dqY1[i, 0] := d.dqY1[0, 0]; d.dqY1[i, 1] := d.dqY1[0, 1];
        d.dqY2[i, 0] := d.dqY2[0, 0]; d.dqY2[i, 1] := d.dqY2[0, 1];
        d.dqUV[i, 0] := d.dqUV[0, 0]; d.dqUV[i, 1] := d.dqUV[0, 1];
        Continue;
      end
      else q := baseQ;
    end;
    d.dqY1[i, 0] := KDcTable[Clip127(q + dqy1dc, 127)];
    d.dqY1[i, 1] := KAcTable[Clip127(q, 127)];
    d.dqY2[i, 0] := KDcTable[Clip127(q + dqy2dc, 127)] * 2;
    d.dqY2[i, 1] := (KAcTable[Clip127(q + dqy2ac, 127)] * 101581) shr 16;
    if d.dqY2[i, 1] < 8 then d.dqY2[i, 1] := 8;
    d.dqUV[i, 0] := KDcTable[Clip127(q + dquvdc, 117)];
    d.dqUV[i, 1] := KAcTable[Clip127(q + dquvac, 127)];
  end;
end;

procedure ParseProba(var d: TDec);
var t, b, c, p, idx: Integer;
begin
  idx := 0;
  for t := 0 to 3 do
    for b := 0 to 7 do
      for c := 0 to 2 do
        for p := 0 to 10 do
        begin
          if BD_GetBit(d.br, KCoeffsUpdate[idx]) <> 0 then
            d.Bands[t, b, c, p] := BD_GetLit(d.br, 8)
          else
            d.Bands[t, b, c, p] := KCoeffsProba0[idx];
          Inc(idx);
        end;
  d.useSkipProba := BD_GetBit(d.br, 128) <> 0;
  if d.useSkipProba then d.skipP := BD_GetLit(d.br, 8);
end;

{ ---- intra-mode parsing (partition 0) ---------------------------------- }

procedure ParseIntraMode(var d: TDec; mb_x: Integer);
var top, left: PByte; blk: ^TMBData; ymode, x, y: Integer; prob: PByte; bm: Integer;
begin
  top := PByte(@d.intraT[4 * mb_x]);
  left := PByte(@d.intraL[0]);
  blk := @d.mbrow[mb_x];

  if d.updateMap then
  begin
    if BD_GetBit(d.br, d.segProb[0]) = 0 then
      blk^.segment := BD_GetBit(d.br, d.segProb[1])
    else
      blk^.segment := BD_GetBit(d.br, d.segProb[2]) + 2;
  end
  else blk^.segment := 0;

  blk^.skip := 0;
  if d.useSkipProba then blk^.skip := Byte(BD_GetBit(d.br, d.skipP));

  blk^.is_i4x4 := BD_GetBit(d.br, 145) = 0;
  if not blk^.is_i4x4 then
  begin
    if BD_GetBit(d.br, 156) <> 0 then
    begin
      if BD_GetBit(d.br, 128) <> 0 then ymode := TM_PRED else ymode := H_PRED;
    end
    else
    begin
      if BD_GetBit(d.br, 163) <> 0 then ymode := V_PRED else ymode := DC_PRED;
    end;
    blk^.imodes[0] := ymode;
    for x := 0 to 3 do top[x] := ymode;
    for y := 0 to 3 do left[y] := ymode;
  end
  else
  begin
    for y := 0 to 3 do
    begin
      ymode := left[y];
      for x := 0 to 3 do
      begin
        prob := PByte(@KBModesProba[(top[x] * 10 + ymode) * 9]);
        if BD_GetBit(d.br, prob[0]) = 0 then bm := B_DC_PRED
        else if BD_GetBit(d.br, prob[1]) = 0 then bm := B_TM_PRED
        else if BD_GetBit(d.br, prob[2]) = 0 then bm := B_VE_PRED
        else if BD_GetBit(d.br, prob[3]) = 0 then
        begin
          if BD_GetBit(d.br, prob[4]) = 0 then bm := B_HE_PRED
          else if BD_GetBit(d.br, prob[5]) = 0 then bm := B_RD_PRED
          else bm := B_VR_PRED;
        end
        else
        begin
          if BD_GetBit(d.br, prob[6]) = 0 then bm := B_LD_PRED
          else if BD_GetBit(d.br, prob[7]) = 0 then bm := B_VL_PRED
          else if BD_GetBit(d.br, prob[8]) = 0 then bm := B_HD_PRED
          else bm := B_HU_PRED;
        end;
        ymode := bm;
        top[x] := bm;
        blk^.imodes[y * 4 + x] := bm;
      end;
      left[y] := ymode;
    end;
  end;
  if BD_GetBit(d.br, 142) = 0 then blk^.uvmode := DC_PRED
  else if BD_GetBit(d.br, 114) = 0 then blk^.uvmode := V_PRED
  else if BD_GetBit(d.br, 183) <> 0 then blk^.uvmode := TM_PRED
  else blk^.uvmode := H_PRED;
end;

{ ---- residual (token) decoding (§13) ----------------------------------- }

function GetLargeValue(var br: TBoolDec; p: PByte): Integer;
var v, bit1, bit0, cat, i: Integer; tab: PByte; n: Integer;
begin
  if BD_GetBit(br, p[3]) = 0 then
  begin
    if BD_GetBit(br, p[4]) = 0 then v := 2
    else v := 3 + BD_GetBit(br, p[5]);
  end
  else
  begin
    if BD_GetBit(br, p[6]) = 0 then
    begin
      if BD_GetBit(br, p[7]) = 0 then v := 5 + BD_GetBit(br, 159)
      else begin v := 7 + 2 * BD_GetBit(br, 165); v := v + BD_GetBit(br, 145); end;
    end
    else
    begin
      bit1 := BD_GetBit(br, p[8]);
      bit0 := BD_GetBit(br, p[9 + bit1]);
      cat := 2 * bit1 + bit0;
      v := 0;
      case cat of
        0: begin tab := @KCat3[0]; n := 3; end;
        1: begin tab := @KCat4[0]; n := 4; end;
        2: begin tab := @KCat5[0]; n := 5; end;
      else begin tab := @KCat6[0]; n := 11; end;
      end;
      for i := 0 to n - 1 do v := v + v + BD_GetBit(br, tab[i]);
      v := v + 3 + (8 shl cat);
    end;
  end;
  Result := v;
end;

// returns position of last non-zero coeff + 1
function GetCoeffs(var d: TDec; var br: TBoolDec; typ, ctx, dqDC, dqAC, first: Integer;
  outp: PSmallInt): Integer;
var n, v, dq: Integer; p: PByte;
begin
  n := first;
  p := PByte(@d.Bands[typ, KBands[n], ctx, 0]);
  while n < 16 do
  begin
    if BD_GetBit(br, p[0]) = 0 then Exit(n);
    while BD_GetBit(br, p[1]) = 0 do
    begin
      Inc(n);
      p := PByte(@d.Bands[typ, KBands[n], 0, 0]);
      if n = 16 then Exit(16);
    end;
    // non-zero coeff
    if BD_GetBit(br, p[2]) = 0 then
    begin
      v := 1;
      p := PByte(@d.Bands[typ, KBands[n + 1], 1, 0]);
    end
    else
    begin
      v := GetLargeValue(br, p);
      p := PByte(@d.Bands[typ, KBands[n + 1], 2, 0]);
    end;
    if n > 0 then dq := dqAC else dq := dqDC;
    outp[KZigzag[n]] := SmallInt((BD_GetSigned(br, v) * dq) and $FFFF);
    Inc(n);
  end;
  Result := 16;
end;

function NzCodeBits(nz_coeffs: Cardinal; nz, dc_nz: Integer): Cardinal; inline;
begin
  nz_coeffs := nz_coeffs shl 2;
  if nz > 3 then nz_coeffs := nz_coeffs or 3
  else if nz > 1 then nz_coeffs := nz_coeffs or 2
  else nz_coeffs := nz_coeffs or Cardinal(dc_nz);
  Result := nz_coeffs;
end;

// returns True if the whole MB is empty (mb_skip inference)
function ParseResiduals(var d: TDec; mb_x: Integer; var tbr: TBoolDec): Boolean;
var
  blk: ^TMBData; mb, left: ^TMB; dst: PSmallInt;
  seg, ctx, nz, i, dc0, x, y, ch, l, first, acType: Integer;
  tnz, lnz: Integer;
  non_zero_y, non_zero_uv, nz_coeffs, out_t_nz, out_l_nz: Cardinal;
  dc: array[0..15] of SmallInt;
begin
  blk := @d.mbrow[mb_x];
  mb := @d.top[mb_x];
  left := @d.leftMB;
  seg := blk^.segment;
  dst := @blk^.coeffs[0];
  FillChar(blk^.coeffs, SizeOf(blk^.coeffs), 0);
  non_zero_y := 0; non_zero_uv := 0;

  if not blk^.is_i4x4 then
  begin
    FillChar(dc, SizeOf(dc), 0);
    ctx := mb^.nz_dc + left^.nz_dc;
    nz := GetCoeffs(d, tbr, 1, ctx, d.dqY2[seg, 0], d.dqY2[seg, 1], 0, @dc[0]);
    mb^.nz_dc := Ord(nz > 0); left^.nz_dc := mb^.nz_dc;
    if nz > 1 then
      TransformWHT(@dc[0], dst)
    else
    begin
      dc0 := ASR(dc[0] + 3, 3);
      i := 0;
      while i < 16 * 16 do begin dst[i] := SmallInt(dc0 and $FFFF); Inc(i, 16); end;
    end;
    first := 1; acType := 0;
  end
  else
  begin
    first := 0; acType := 3;
  end;

  tnz := mb^.nz and $0f;
  lnz := left^.nz and $0f;
  for y := 0 to 3 do
  begin
    l := lnz and 1;
    nz_coeffs := 0;
    for x := 0 to 3 do
    begin
      ctx := l + (tnz and 1);
      nz := GetCoeffs(d, tbr, acType, ctx, d.dqY1[seg, 0], d.dqY1[seg, 1], first, dst);
      if nz > first then l := 1 else l := 0;
      tnz := (tnz shr 1) or (l shl 7);
      nz_coeffs := NzCodeBits(nz_coeffs, nz, Ord(dst[0] <> 0));
      dst := dst + 16;
    end;
    tnz := tnz shr 4;
    lnz := (lnz shr 1) or (l shl 7);
    non_zero_y := (non_zero_y shl 8) or nz_coeffs;
  end;
  out_t_nz := Cardinal(tnz);
  out_l_nz := Cardinal(lnz shr 4);

  ch := 0;
  while ch < 4 do
  begin
    nz_coeffs := 0;
    tnz := (mb^.nz shr (4 + ch));
    lnz := (left^.nz shr (4 + ch));
    for y := 0 to 1 do
    begin
      l := lnz and 1;
      for x := 0 to 1 do
      begin
        ctx := l + (tnz and 1);
        nz := GetCoeffs(d, tbr, 2, ctx, d.dqUV[seg, 0], d.dqUV[seg, 1], 0, dst);
        if nz > 0 then l := 1 else l := 0;
        tnz := (tnz shr 1) or (l shl 3);
        nz_coeffs := NzCodeBits(nz_coeffs, nz, Ord(dst[0] <> 0));
        dst := dst + 16;
      end;
      tnz := tnz shr 2;
      lnz := (lnz shr 1) or (l shl 5);
    end;
    non_zero_uv := non_zero_uv or (nz_coeffs shl (4 * ch));
    out_t_nz := out_t_nz or ((Cardinal(tnz) shl 4) shl ch);
    out_l_nz := out_l_nz or (Cardinal(lnz and $f0) shl ch);
    Inc(ch, 2);
  end;
  mb^.nz := Byte(out_t_nz);
  left^.nz := Byte(out_l_nz);

  blk^.non_zero_y := non_zero_y;
  blk^.non_zero_uv := non_zero_uv;
  Result := (non_zero_y or non_zero_uv) = 0;
end;

{ ---- reconstruction ---------------------------------------------------- }

function CheckMode(mb_x, mb_y, mode: Integer): Integer; inline;
begin
  if mode = B_DC_PRED then
  begin
    if mb_x = 0 then
    begin
      if mb_y = 0 then Result := B_DC_PRED_NOTOPLEFT else Result := B_DC_PRED_NOLEFT;
    end
    else
    begin
      if mb_y = 0 then Result := B_DC_PRED_NOTOP else Result := B_DC_PRED;
    end;
  end
  else Result := mode;
end;

procedure Copy4(dst, src: PByte); inline;
begin PCardinal(dst)^ := PCardinal(src)^; end;

procedure DoTransform(bits: Cardinal; src: PSmallInt; dst: PByte); inline;
begin
  case bits shr 30 of
    3: TransformOneTwo(src, dst, False);
    2: TransformAC3(src, dst);
    1: TransformDC(src, dst);
  end;
end;

procedure DoUVTransform(bits: Cardinal; src: PSmallInt; dst: PByte); inline;
begin
  if (bits and $ff) <> 0 then
  begin
    if (bits and $aa) <> 0 then TransformUV(src, dst)
    else TransformDCUV(src, dst);
  end;
end;

procedure ReconstructRow(var d: TDec; mb_y: Integer);
var
  yD, uD, vD, dst: PByte; j, k, mb_x, n, pf: Integer; blk: ^TMBData; bits: Cardinal;
  yi, ui, vi: Integer;
begin
  yD := PByte(@d.work[Y_OFF]); uD := PByte(@d.work[U_OFF]); vD := PByte(@d.work[V_OFF]);

  for j := 0 to 15 do (yD + j * BPS - 1)^ := 129;
  for j := 0 to 7 do begin (uD + j * BPS - 1)^ := 129; (vD + j * BPS - 1)^ := 129; end;
  if mb_y > 0 then
  begin
    (yD - 1 - BPS)^ := 129; (uD - 1 - BPS)^ := 129; (vD - 1 - BPS)^ := 129;
  end
  else
  begin
    for k := 0 to 20 do (yD - BPS - 1 + k)^ := 127;
    for k := 0 to 8 do (uD - BPS - 1 + k)^ := 127;
    for k := 0 to 8 do (vD - BPS - 1 + k)^ := 127;
  end;

  for mb_x := 0 to d.mb_w - 1 do
  begin
    blk := @d.mbrow[mb_x];

    if mb_x > 0 then
    begin
      for j := -1 to 15 do Copy4(yD + j * BPS - 4, yD + j * BPS + 12);
      for j := -1 to 7 do
      begin
        Copy4(uD + j * BPS - 4, uD + j * BPS + 4);
        Copy4(vD + j * BPS - 4, vD + j * BPS + 4);
      end;
    end;

    if mb_y > 0 then
    begin
      Move(d.yuvt[mb_x].y[0], (yD - BPS)^, 16);
      Move(d.yuvt[mb_x].u[0], (uD - BPS)^, 8);
      Move(d.yuvt[mb_x].v[0], (vD - BPS)^, 8);
    end;

    if blk^.is_i4x4 then
    begin
      if mb_y > 0 then
      begin
        if mb_x >= d.mb_w - 1 then
          for k := 0 to 3 do (yD - BPS + 16 + k)^ := d.yuvt[mb_x].y[15]
        else
          Move(d.yuvt[mb_x + 1].y[0], (yD - BPS + 16)^, 4);
      end;
      // replicate the 4 top-right samples down into the rightmost sub-column's
      // top-right slots. libwebp treats top_right as uint32_t*, so top_right[BPS]
      // steps BPS*4 bytes = 4 rows -> targets rows 3, 7, 11 at column 16.
      Copy4(yD - BPS + 16 + 4 * BPS, yD - BPS + 16);
      Copy4(yD - BPS + 16 + 8 * BPS, yD - BPS + 16);
      Copy4(yD - BPS + 16 + 12 * BPS, yD - BPS + 16);

      bits := blk^.non_zero_y;
      for n := 0 to 15 do
      begin
        dst := yD + KScan[n];
        PredLuma4(blk^.imodes[n], dst);
        DoTransform(bits, @blk^.coeffs[n * 16], dst);
        bits := bits shl 2;
      end;
    end
    else
    begin
      pf := CheckMode(mb_x, mb_y, blk^.imodes[0]);
      PredLuma16(pf, yD);
      bits := blk^.non_zero_y;
      if bits <> 0 then
        for n := 0 to 15 do
        begin
          DoTransform(bits, @blk^.coeffs[n * 16], yD + KScan[n]);
          bits := bits shl 2;
        end;
    end;

    pf := CheckMode(mb_x, mb_y, blk^.uvmode);
    PredChroma8(pf, uD);
    PredChroma8(pf, vD);
    DoUVTransform(blk^.non_zero_uv, @blk^.coeffs[16 * 16], uD);
    DoUVTransform(blk^.non_zero_uv shr 8, @blk^.coeffs[20 * 16], vD);

    if mb_y < d.mb_h - 1 then
    begin
      Move((yD + 15 * BPS)^, d.yuvt[mb_x].y[0], 16);
      Move((uD + 7 * BPS)^, d.yuvt[mb_x].u[0], 8);
      Move((vD + 7 * BPS)^, d.yuvt[mb_x].v[0], 8);
    end;

    // copy reconstructed MB into full planes
    yi := (mb_y * 16) * d.sY + mb_x * 16;
    for j := 0 to 15 do Move((yD + j * BPS)^, d.Ybuf[yi + j * d.sY], 16);
    ui := (mb_y * 8) * d.sUV + mb_x * 8;
    vi := ui;
    for j := 0 to 7 do
    begin
      Move((uD + j * BPS)^, d.Ubuf[ui + j * d.sUV], 8);
      Move((vD + j * BPS)^, d.Vbuf[vi + j * d.sUV], 8);
    end;
  end;
end;

{ ---- loop filter driver ------------------------------------------------ }

procedure PrecomputeFilterStrengths(var d: TDec);
var s, i4x4, baseLevel, level, ilevel: Integer;
begin
  if d.filterType = 0 then Exit;
  for s := 0 to 3 do
  begin
    if d.useSeg then
    begin
      baseLevel := d.segFilter[s];
      if not d.absDelta then baseLevel := baseLevel + d.fLevel;
    end
    else baseLevel := d.fLevel;
    for i4x4 := 0 to 1 do
    begin
      level := baseLevel;
      if d.useLfDelta then
      begin
        level := level + d.refLf[0];
        if i4x4 <> 0 then level := level + d.modeLf[0];
      end;
      if level < 0 then level := 0 else if level > 63 then level := 63;
      if level > 0 then
      begin
        ilevel := level;
        if d.fSharp > 0 then
        begin
          if d.fSharp > 4 then ilevel := ilevel shr 2 else ilevel := ilevel shr 1;
          if ilevel > 9 - d.fSharp then ilevel := 9 - d.fSharp;
        end;
        if ilevel < 1 then ilevel := 1;
        d.fstrength[s, i4x4].f_ilevel := ilevel;
        d.fstrength[s, i4x4].f_limit := 2 * level + ilevel;
        if level >= 40 then d.fstrength[s, i4x4].hev_thresh := 2
        else if level >= 15 then d.fstrength[s, i4x4].hev_thresh := 1
        else d.fstrength[s, i4x4].hev_thresh := 0;
      end
      else d.fstrength[s, i4x4].f_limit := 0;
      d.fstrength[s, i4x4].f_inner := i4x4;
    end;
  end;
end;

procedure FilterFrame(var d: TDec);
var
  mb_x, mb_y, seg, i4, limit, ilevel, hevt, inner, idx: Integer;
  yp, up, vp: PByte;
begin
  if d.filterType = 0 then Exit;
  for mb_y := 0 to d.mb_h - 1 do
    for mb_x := 0 to d.mb_w - 1 do
    begin
      idx := mb_y * d.mb_w + mb_x;
      seg := d.fSegA[idx]; i4 := d.fI4A[idx];
      limit := d.fstrength[seg, i4].f_limit;
      if limit = 0 then Continue;
      ilevel := d.fstrength[seg, i4].f_ilevel;
      hevt := d.fstrength[seg, i4].hev_thresh;
      inner := d.fstrength[seg, i4].f_inner;
      if d.fSkipA[idx] = 0 then inner := 1;

      yp := PByte(@d.Ybuf[(mb_y * 16) * d.sY + mb_x * 16]);
      if d.filterType = 1 then
      begin
        if mb_x > 0 then SimpleHFilter16(yp, d.sY, limit + 4);
        if inner <> 0 then SimpleHFilter16i(yp, d.sY, limit);
        if mb_y > 0 then SimpleVFilter16(yp, d.sY, limit + 4);
        if inner <> 0 then SimpleVFilter16i(yp, d.sY, limit);
      end
      else
      begin
        up := PByte(@d.Ubuf[(mb_y * 8) * d.sUV + mb_x * 8]);
        vp := PByte(@d.Vbuf[(mb_y * 8) * d.sUV + mb_x * 8]);
        if mb_x > 0 then
        begin
          HFilter16(yp, d.sY, limit + 4, ilevel, hevt);
          HFilter8(up, vp, d.sUV, limit + 4, ilevel, hevt);
        end;
        if inner <> 0 then
        begin
          HFilter16i(yp, d.sY, limit, ilevel, hevt);
          HFilter8i(up, vp, d.sUV, limit, ilevel, hevt);
        end;
        if mb_y > 0 then
        begin
          VFilter16(yp, d.sY, limit + 4, ilevel, hevt);
          VFilter8(up, vp, d.sUV, limit + 4, ilevel, hevt);
        end;
        if inner <> 0 then
        begin
          VFilter16i(yp, d.sY, limit, ilevel, hevt);
          VFilter8i(up, vp, d.sUV, limit, ilevel, hevt);
        end;
      end;
    end;
end;

{ ---- YUV -> RGBA (fancy upsampling, §11 + libwebp yuv.h/upsampling.c) --- }

function MultHi(v, coeff: Integer): Integer; inline;
begin Result := (v * coeff) shr 8; end;

function VP8Clip8(v: Integer): Integer; inline;
const YUV_MASK2 = (256 shl 6) - 1;
begin
  if (v and (not YUV_MASK2)) = 0 then Result := v shr 6
  else if v < 0 then Result := 0
  else Result := 255;
end;

procedure YuvToRgba(y, u, v: Integer; rgba: PByte); inline;
begin
  rgba[0] := VP8Clip8(MultHi(y, 19077) + MultHi(v, 26149) - 14234);            // R
  rgba[1] := VP8Clip8(MultHi(y, 19077) - MultHi(u, 6419) - MultHi(v, 13320) + 8708); // G
  rgba[2] := VP8Clip8(MultHi(y, 19077) + MultHi(u, 33050) - 17685);           // B
  rgba[3] := 255;
end;

// One upsampled line-pair. Row indices index into the (already reconstructed +
// filtered) Y/U/V planes; dst rows index into RGBA. botY / botDst < 0 => absent.
procedure UpsampleLinePair(var d: TDec; topYr, botYr, topUVr, curUVr, topDr, botDr, len: Integer);
var
  x, lastPair: Integer;
  tlu, tlv, lu, lv, tu, tv, cu, cv: Integer;
  avgU, avgV, d12u, d12v, d03u, d03v, u0, v0, u1, v1: Integer;
  yTop, yBot: PByte; uT, vT, uC, vC: PByte; dTop, dBot: PByte;
begin
  yTop := PByte(@d.Ybuf[topYr * d.sY]);
  if botYr >= 0 then yBot := PByte(@d.Ybuf[botYr * d.sY]) else yBot := nil;
  uT := PByte(@d.Ubuf[topUVr * d.sUV]); vT := PByte(@d.Vbuf[topUVr * d.sUV]);
  uC := PByte(@d.Ubuf[curUVr * d.sUV]); vC := PByte(@d.Vbuf[curUVr * d.sUV]);
  dTop := d.pRGBA + topDr * (d.W * 4);
  if botDr >= 0 then dBot := d.pRGBA + botDr * (d.W * 4) else dBot := nil;

  lastPair := (len - 1) shr 1;
  tlu := uT[0]; tlv := vT[0];
  lu := uC[0]; lv := vC[0];

  u0 := (3 * tlu + lu + 2) shr 2; v0 := (3 * tlv + lv + 2) shr 2;
  YuvToRgba(yTop[0], u0, v0, dTop);
  if yBot <> nil then
  begin
    u0 := (3 * lu + tlu + 2) shr 2; v0 := (3 * lv + tlv + 2) shr 2;
    YuvToRgba(yBot[0], u0, v0, dBot);
  end;

  for x := 1 to lastPair do
  begin
    tu := uT[x]; tv := vT[x];
    cu := uC[x]; cv := vC[x];
    avgU := tlu + tu + lu + cu + 8; avgV := tlv + tv + lv + cv + 8;
    d12u := (avgU + 2 * (tu + lu)) shr 3; d12v := (avgV + 2 * (tv + lv)) shr 3;
    d03u := (avgU + 2 * (tlu + cu)) shr 3; d03v := (avgV + 2 * (tlv + cv)) shr 3;

    u0 := (d12u + tlu) shr 1; v0 := (d12v + tlv) shr 1;
    u1 := (d03u + tu) shr 1; v1 := (d03v + tv) shr 1;
    YuvToRgba(yTop[2 * x - 1], u0, v0, dTop + (2 * x - 1) * 4);
    YuvToRgba(yTop[2 * x - 0], u1, v1, dTop + (2 * x - 0) * 4);
    if yBot <> nil then
    begin
      u0 := (d03u + lu) shr 1; v0 := (d03v + lv) shr 1;
      u1 := (d12u + cu) shr 1; v1 := (d12v + cv) shr 1;
      YuvToRgba(yBot[2 * x - 1], u0, v0, dBot + (2 * x - 1) * 4);
      YuvToRgba(yBot[2 * x - 0], u1, v1, dBot + (2 * x - 0) * 4);
    end;
    tlu := tu; tlv := tv; lu := cu; lv := cv;
  end;

  if (len and 1) = 0 then
  begin
    u0 := (3 * tlu + lu + 2) shr 2; v0 := (3 * tlv + lv + 2) shr 2;
    YuvToRgba(yTop[len - 1], u0, v0, dTop + (len - 1) * 4);
    if yBot <> nil then
    begin
      u0 := (3 * lu + tlu + 2) shr 2; v0 := (3 * lv + tlv + 2) shr 2;
      YuvToRgba(yBot[len - 1], u0, v0, dBot + (len - 1) * 4);
    end;
  end;
end;

procedure EmitFancyRGB(var d: TDec);
var y, yEnd, curYr, curUVr, topUVr, dstR, W, H: Integer;
begin
  W := d.W; H := d.H;
  curYr := 0; curUVr := 0; dstR := 0;
  yEnd := H;

  // first line: mirror u/v at boundary
  UpsampleLinePair(d, 0, -1, 0, 0, 0, -1, W);

  y := 0;
  while y + 2 < yEnd do
  begin
    topUVr := curUVr;
    Inc(curUVr);
    Inc(dstR, 2);
    Inc(curYr, 2);
    UpsampleLinePair(d, curYr - 1, curYr, topUVr, curUVr, dstR - 1, dstR, W);
    Inc(y, 2);
  end;
  Inc(curYr);
  if (yEnd and 1) = 0 then
    UpsampleLinePair(d, curYr, -1, curUVr, curUVr, dstR + 1, -1, W);
end;

{ ---- top-level --------------------------------------------------------- }

function Tina4DecodeVP8(Data: PByte; Size: Integer; out RGBA: TBytes;
  out W, H: Integer): Boolean;
var
  d: PDec;
  bits: Cardinal; keyFrame: Boolean; partLen, i, s: Integer;
  buf: PByte; bufSize: Integer;
  part0: PByte; part0Len: Integer;
  szp, partStart: PByte; sizeLeft, psize, lastPart, p: Integer;
  mb_x, mb_y: Integer; tbr: ^TBoolDec;
begin
  Result := False; W := 0; H := 0;
  if (Data = nil) or (Size < 10) then Exit;

  bits := Data[0] or (Data[1] shl 8) or (Data[2] shl 16);
  keyFrame := (bits and 1) = 0;
  if not keyFrame then Exit;
  if ((bits shr 1) and 7) > 3 then Exit;      // profile
  if ((bits shr 4) and 1) = 0 then Exit;      // must be shown
  partLen := bits shr 5;
  // start code
  if not ((Data[3] = $9d) and (Data[4] = $01) and (Data[5] = $2a)) then Exit;

  New(d);
  try
    FillChar(d^, SizeOf(TDec), 0);
    d^.absDelta := True;
    for i := 0 to 2 do d^.segProb[i] := 255;

    d^.W := (Data[6] or (Data[7] shl 8)) and $3fff;
    d^.H := (Data[8] or (Data[9] shl 8)) and $3fff;
    if (d^.W = 0) or (d^.H = 0) then Exit;
    d^.mb_w := (d^.W + 15) shr 4;
    d^.mb_h := (d^.H + 15) shr 4;

    buf := Data + 10;
    bufSize := Size - 10;
    if partLen > bufSize then Exit;

    // partition 0 (header + intra modes)
    BD_Init(d^.br, buf, partLen);
    part0 := buf + partLen;
    part0Len := bufSize - partLen;

    // key-frame colour space + clamp
    BD_GetBit(d^.br, 128);   // colorspace
    BD_GetBit(d^.br, 128);   // clamp_type

    ParseSegmentHeader(d^);
    ParseFilterHeader(d^);

    // token partitions
    d^.nPartsM1 := (1 shl BD_GetLit(d^.br, 2)) - 1;
    lastPart := d^.nPartsM1;
    if part0Len < 3 * lastPart then Exit;
    szp := part0;
    partStart := part0 + lastPart * 3;
    sizeLeft := part0Len - lastPart * 3;
    for p := 0 to lastPart - 1 do
    begin
      psize := szp[0] or (szp[1] shl 8) or (szp[2] shl 16);
      if psize > sizeLeft then psize := sizeLeft;
      BD_Init(d^.parts[p], partStart, psize);
      partStart := partStart + psize;
      sizeLeft := sizeLeft - psize;
      szp := szp + 3;
    end;
    BD_Init(d^.parts[lastPart], partStart, sizeLeft);

    ParseQuant(d^);
    BD_GetBit(d^.br, 128);          // ignore update_proba flag (key frame)
    ParseProba(d^);

    // allocate frame buffers
    d^.sY := d^.mb_w * 16; d^.sUV := d^.mb_w * 8;
    SetLength(d^.Ybuf, d^.sY * d^.mb_h * 16);
    SetLength(d^.Ubuf, d^.sUV * d^.mb_h * 8);
    SetLength(d^.Vbuf, d^.sUV * d^.mb_h * 8);
    SetLength(d^.top, d^.mb_w);
    SetLength(d^.intraT, d^.mb_w * 4);
    SetLength(d^.yuvt, d^.mb_w);
    SetLength(d^.mbrow, d^.mb_w);
    SetLength(d^.fSegA, d^.mb_w * d^.mb_h);
    SetLength(d^.fI4A, d^.mb_w * d^.mb_h);
    SetLength(d^.fSkipA, d^.mb_w * d^.mb_h);
    for i := 0 to d^.mb_w * 4 - 1 do d^.intraT[i] := B_DC_PRED;
    for i := 0 to d^.mb_w - 1 do begin d^.top[i].nz := 0; d^.top[i].nz_dc := 0; end;

    // main decode loop: per MB-row parse modes (part0), residuals (token part),
    // then reconstruct the row into the full planes.
    for mb_y := 0 to d^.mb_h - 1 do
    begin
      // reset left contexts (VP8InitScanline)
      d^.leftMB.nz := 0; d^.leftMB.nz_dc := 0;
      for i := 0 to 3 do d^.intraL[i] := B_DC_PRED;

      for mb_x := 0 to d^.mb_w - 1 do ParseIntraMode(d^, mb_x);

      tbr := @d^.parts[mb_y and d^.nPartsM1];
      for mb_x := 0 to d^.mb_w - 1 do
      begin
        // VP8DecodeMB
        if d^.useSkipProba and (d^.mbrow[mb_x].skip <> 0) then
        begin
          d^.leftMB.nz := 0; d^.top[mb_x].nz := 0;
          if not d^.mbrow[mb_x].is_i4x4 then
          begin d^.leftMB.nz_dc := 0; d^.top[mb_x].nz_dc := 0; end;
          d^.mbrow[mb_x].non_zero_y := 0;
          d^.mbrow[mb_x].non_zero_uv := 0;
        end
        else
          ParseResiduals(d^, mb_x, tbr^);

        // stash filter source info
        s := mb_y * d^.mb_w + mb_x;
        d^.fSegA[s] := d^.mbrow[mb_x].segment;
        d^.fI4A[s] := Ord(d^.mbrow[mb_x].is_i4x4);
        if d^.useSkipProba then d^.fSkipA[s] := d^.mbrow[mb_x].skip else d^.fSkipA[s] := 0;
      end;

      ReconstructRow(d^, mb_y);
    end;

    // in-loop deblocking over the full frame
    PrecomputeFilterStrengths(d^);
    FilterFrame(d^);

    // upsample + convert to RGBA
    W := d^.W; H := d^.H;
    SetLength(RGBA, W * H * 4);
    d^.pRGBA := PByte(@RGBA[0]);
    EmitFancyRGB(d^);

    Result := True;
  finally
    Dispose(d);
  end;
end;

end.
