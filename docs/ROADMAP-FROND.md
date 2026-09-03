# Roadmap: Frond template engine (the last piece)

Frond closes the loop. The renderer displays HTML; the data layer supplies
data; **Frond turns `template + data` into the HTML string** the renderer
shows. With it, a Tina4Pascal app is what a Tina4 backend app already is —
templates driven by data — but running native, offline, in one binary.

```
data (api/ws/sse)  ─▶  Frond(template, data) ─▶ HTML string ─▶ Render.SetHTML/SetInnerHTML ─▶ pixels
        ▲                                                                                   │
        └───────────────────────  semantic events (click/submit)  ◀───────────────────────┘
```

## Port source

`Tina4Frond.pas` in tina4delphi is a complete Twig-compatible engine
(~7400 lines) — this is a **port**, same recipe as `Tina4HTMLDom`, not a
green-field build. It is pure `string → string` with **zero OS dependencies**,
so it compiles on every target and needs no platform shell. It can even be
unit-tested headlessly on all six targets today.

Verified surface to mirror:
```pascal
Frond := TTina4Frond.Create;
Frond.TemplatePath := 'templates/';        // dir; else treat arg as inline
Frond.SetVariable('user', userValue);
html := Frond.Render('profile.twig', extraVars);   // filename or inline string
```

## Feature set to port (all present in the Delphi engine)

- **Output**: `{{ expr }}` with autoescape (HTML-escape by default;
  `{% autoescape false %}` / `|raw` to opt out).
- **Comments**: `{# ... #}`.
- **Control**: `{% if %}/{% elseif %}/{% else %}/{% endif %}`,
  `{% for x in list %}…{% else %}…{% endfor %}` (incl. `loop.index` etc.),
  `{% set name = expr %}`.
- **Composition**: `{% include 'partial.twig' %}`,
  `{% extends 'base.twig' %}` + `{% block name %}…{% endblock %}` overrides.
- **Expressions**: an infix tokenizer → RPN evaluator supporting arithmetic,
  comparisons, `and/or/not`, `in`, `starts with`, `ends with`, `matches`
  (regex), the `..` range, ternary, member/`.`/`[]` access, function calls.
- **Filters** (pipe): `upper, lower, capitalize, trim, length, join, default,
  date, number_format, json_encode, escape, raw, nl2br` — extensible.

## The one real adaptation: the value type

Delphi Frond uses `TValue` (RTTI) + `TDictionary<String,TValue>`. FPC's RTTI
`TValue` is thinner, so define a small tagged value instead:

```pascal
TFrondKind = (fkNull, fkStr, fkInt, fkFloat, fkBool, fkArray, fkDict);
TFrondValue = record
  Kind: TFrondKind;
  // str/num/bool + TList<TFrondValue> / TDictionary<string,TFrondValue>
end;
```
Everything else (tokenizer, RPN, tags, filters) ports almost line-for-line.
A JSON bridge (`FrondValueFromJSON(TJSONData)`) makes API/WS/SSE payloads
render directly — the data layer and Frond meet here.

## Integration with the renderer

- Whole page: `Render.SetHTML(Frond.Render('page.twig', data))`.
- Live region: `Render.SetInnerHTML('feed', Frond.Render('row.twig', msg))`
  from a WebSocket `OnMessage` — the reactive update path from the data-layer
  roadmap, now template-driven.
- Templates live on disk (desktop) or bundled as assets (Android/iOS); the
  same `~/.cache`/asset access the image pipeline already uses.

## Build order

1. `TFrondValue` + JSON bridge + `tests/test_frond.pas` (headless, runs on
   every target).
2. Port tokenizer + RPN expression evaluator (self-contained; heavily unit
   tested).
3. Port output/comment/if/for/set.
4. Port filters.
5. Port include/extends/block composition + `TemplatePath` loading.
6. `examples/live/`: Frond template + a WS feed rendering rows — the full
   `data → template → HTML → native pixels` loop, cross-compiled.

## Why Frond is genuinely last (and safe)

It has no dependency on the renderer, the shells, or the data layer — it is a
pure function. It can be ported and fully tested in isolation on day one, then
snapped into place. When it lands, the stack is complete: **Frond (templates)
→ Tina4HTMLDom/Layout (render) → shells (native window) + data layer
(live) → six platforms from one Mac.**
