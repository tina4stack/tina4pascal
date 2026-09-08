{ Generated from calculator.html by gen_ui_inc.sh — do not edit by hand.
  Embeds the UI so the binary ships standalone (no external asset). }
const CALC_HTML =
  '<!doctype html>'#10 +
  '<html>'#10 +
  '<head>'#10 +
  '<meta charset="utf-8">'#10 +
  '<style>'#10 +
  '  * { box-sizing: border-box; }'#10 +
  '  /* dark on the root so it fills the whole window (canvas background), and on'#10 +
  '     body; centre the calc with margin:auto rather than flex centring */'#10 +
  '  html { background: #0b0b0f; }'#10 +
  '  body {'#10 +
  '    margin: 0; background: #0b0b0f; color: #fff;'#10 +
  '    font-family: "Segoe UI", Helvetica, Arial, sans-serif;'#10 +
  '    text-align: center;                 /* centres the inline-block calc */'#10 +
  '  }'#10 +
  '  .calc {'#10 +
  '    display: inline-block; text-align: left; vertical-align: top;'#10 +
  '    width: 380px; padding: 14px 14px 18px;'#10 +
  '  }'#10 +
  ''#10 +
  '  /* readout */'#10 +
  '  .screen { padding: 20px 14px 12px; text-align: right; }'#10 +
  '  .expr {'#10 +
  '    min-height: 22px; font-size: 17px; font-weight: 600;'#10 +
  '    color: #8a8a91; letter-spacing: .5px; word-break: break-all;'#10 +
  '  }'#10 +
  '  .display {'#10 +
  '    font-size: 62px; font-weight: 300; line-height: 1.05;'#10 +
  '    letter-spacing: -1px; word-break: break-all;'#10 +
  '  }'#10 +
  ''#10 +
  '  /* keypad — fl: rows of flex:1 keys */'#10 +
  '  .row { display: flex; gap: 11px; margin-top: 11px; }'#10 +
  '  .key {'#10 +
  '    flex: 1; height: 62px; border-radius: 31px;'#10 +
  '    display: flex; align-items: center; justify-content: center;'#10 +
  '    font-size: 26px; font-weight: 500; color: #fff;'#10 +
  '    background: #2a2a2e; cursor: pointer; user-select: none;'#10 +
  '  }'#10 +
  '  /* single-class rules layered after .key — the engine matches one class per'#10 +
  '     simple selector, so these override .key by source order, not .key.op */'#10 +
  '  .func { background: #4a4a50; color: #fff; font-weight: 600; }'#10 +
  '  .op   { background: linear-gradient(180deg,#ffb340,#ff9500); color: #fff; font-weight: 600; }'#10 +
  '  .wide { flex: 2.16; justify-content: flex-start; padding-left: 28px; }'#10 +
  '  .eq   { background: linear-gradient(180deg,#ff9f5a,#ff7a00); }'#10 +
  '</style>'#10 +
  '</head>'#10 +
  '<body>'#10 +
  '  <div class="calc">'#10 +
  '    <div class="screen">'#10 +
  '      <div class="expr" id="expr">&nbsp;</div>'#10 +
  '      <div class="display" id="display">0</div>'#10 +
  '    </div>'#10 +
  ''#10 +
  '    <div class="row">'#10 +
  '      <div class="key func" onclick="calc.clear()">AC</div>'#10 +
  '      <div class="key func" onclick="calc.neg()">+/&minus;</div>'#10 +
  '      <div class="key func" onclick="calc.pct()">%</div>'#10 +
  '      <div class="key op"   onclick="calc.op(/)">&divide;</div>'#10 +
  '    </div>'#10 +
  '    <div class="row">'#10 +
  '      <div class="key" onclick="calc.digit(7)">7</div>'#10 +
  '      <div class="key" onclick="calc.digit(8)">8</div>'#10 +
  '      <div class="key" onclick="calc.digit(9)">9</div>'#10 +
  '      <div class="key op" onclick="calc.op(*)">&times;</div>'#10 +
  '    </div>'#10 +
  '    <div class="row">'#10 +
  '      <div class="key" onclick="calc.digit(4)">4</div>'#10 +
  '      <div class="key" onclick="calc.digit(5)">5</div>'#10 +
  '      <div class="key" onclick="calc.digit(6)">6</div>'#10 +
  '      <div class="key op" onclick="calc.op(-)">&minus;</div>'#10 +
  '    </div>'#10 +
  '    <div class="row">'#10 +
  '      <div class="key" onclick="calc.digit(1)">1</div>'#10 +
  '      <div class="key" onclick="calc.digit(2)">2</div>'#10 +
  '      <div class="key" onclick="calc.digit(3)">3</div>'#10 +
  '      <div class="key op" onclick="calc.op(+)">+</div>'#10 +
  '    </div>'#10 +
  '    <div class="row">'#10 +
  '      <div class="key wide" onclick="calc.digit(0)">0</div>'#10 +
  '      <div class="key" onclick="calc.dot()">.</div>'#10 +
  '      <div class="key op eq" onclick="calc.eq()">=</div>'#10 +
  '    </div>'#10 +
  '  </div>'#10 +
  '</body>'#10 +
  '</html>'#10;
