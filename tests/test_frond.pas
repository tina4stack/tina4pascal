program test_frond;

{ Frond template engine tests — output, dotted access, filters, if/elseif/else,
  for + loop, set, include, extends/block inheritance, comments, whitespace
  control, auto-escaping, custom filters/globals. Prints "ALL TESTS PASS". }

{$mode delphi}{$H+}

uses
  SysUtils, Classes, fpjson, jsonparser, Tina4Frond;

var
  Passed, Failed: Integer;

procedure Check(const Got, Want, Name: string);
begin
  if Got = Want then Inc(Passed)
  else begin Inc(Failed); Writeln('FAIL: ', Name); Writeln('   want: [', Want, ']'); Writeln('   got:  [', Got, ']'); end;
end;

function Ctx(const J: string): TJSONObject;
begin Result := TJSONObject(GetJSON(J)); end;

function Up(const Args: array of string): string;
begin if Length(Args) > 0 then Result := UpperCase(Args[0]) else Result := ''; end;

{ write exact content (TStringList would append a trailing newline) }
procedure WriteRaw(const Path, Content: string);
var fs: TFileStream;
begin
  fs := TFileStream.Create(Path, fmCreate);
  try if Content <> '' then fs.WriteBuffer(Content[1], Length(Content));
  finally fs.Free; end;
end;

var
  f: TFrond; c: TJSONObject; dir, base: string; sl: TStringList;
begin
  Passed := 0; Failed := 0;
  f := TFrond.Create;

  c := Ctx('{"name":"Andre","n":1234.5,"items":["a","b","c"],"user":{"active":true,"role":"admin"}}');

  Check(f.RenderString('Hi {{ name }}!', c), 'Hi Andre!', 'output + text');
  Check(f.RenderString('{{ user.role }}', c), 'admin', 'dotted path');
  Check(f.RenderString('{{ items.1 }}', c), 'b', 'array index');
  Check(f.RenderString('{{ name | upper }}', c), 'ANDRE', 'filter upper');
  Check(f.RenderString('{{ n | number_format(2) }}', c), '1234.50', 'filter number_format');
  Check(f.RenderString('{{ missing | default("none") }}', c), 'none', 'filter default');
  Check(f.RenderString('{{ items | length }}', c), '3', 'filter length on array');
  Check(f.RenderString('{{ items | join(", ") }}', c), 'a, b, c', 'filter join');

  { auto-escaping }
  c.Delete('html'); c.Add('html', '<b>&</b>');
  Check(f.RenderString('{{ html }}', c), '&lt;b&gt;&amp;&lt;/b&gt;', 'auto-escape');
  Check(f.RenderString('{{ html | raw }}', c), '<b>&</b>', 'raw disables escape');

  { conditionals }
  Check(f.RenderString('{% if user.active %}on{% else %}off{% endif %}', c), 'on', 'if true');
  Check(f.RenderString('{% if n > 2000 %}big{% elseif n > 1000 %}mid{% else %}small{% endif %}', c), 'mid', 'elseif');
  Check(f.RenderString('{% if user.role == "admin" %}yes{% endif %}', c), 'yes', 'if equals');
  Check(f.RenderString('{% if "b" in items %}has{% endif %}', c), 'has', 'in array');

  { loops }
  Check(f.RenderString('{% for i in items %}{{ i }}{% endfor %}', c), 'abc', 'for loop');
  Check(f.RenderString('{% for i in items %}{{ loop.index }}:{{ i }} {% endfor %}', c),
    '1:a 2:b 3:c ', 'loop.index');
  Check(f.RenderString('{% for i in items %}{% if loop.last %}{{ i }}{% endif %}{% endfor %}', c),
    'c', 'loop.last');

  { set }
  Check(f.RenderString('{% set x = "hi" %}{{ x }}', c), 'hi', 'set literal');
  Check(f.RenderString('{% set x = n * 2 %}{{ x }}', c), '2469', 'set expression');

  { comments + whitespace control }
  Check(f.RenderString('a{# comment #}b', c), 'ab', 'comment stripped');
  Check(f.RenderString('a  {{- name -}}  b', c), 'aAndreb', 'whitespace control');

  { custom filter + global }
  f.AddFilter('shout', @Up);
  f.AddGlobalStr('site', 'Tina4');
  Check(f.RenderString('{{ name | shout }} @ {{ site }}', c), 'ANDRE @ Tina4', 'custom filter + global');

  { include + extends via files }
  dir := IncludeTrailingPathDelimiter(GetTempDir) + 'frond_test';
  ForceDirectories(dir);
  WriteRaw(dir + '/base.twig', 'BASE[{% block body %}default{% endblock %}]');
  WriteRaw(dir + '/p.twig', 'partial:{{ name }}');
  f.Free; f := TFrond.Create(dir);

  Check(f.RenderString('x {% include "p.twig" %} y', c), 'x partial:Andre y', 'include');
  Check(f.RenderString('{% extends "base.twig" %}{% block body %}CHILD {{ name }}{% endblock %}', c),
    'BASE[CHILD Andre]', 'extends + block override');
  Check(f.RenderString('{% extends "base.twig" %}', c), 'BASE[default]', 'extends keeps base block');

  { ---- advanced: macros, tests, parent(), import/from, cache ---- }
  { macros — define + call; macro HTML is safe (not re-escaped) }
  Check(f.RenderString('{% macro greet(who) %}Hi {{ who }}!{% endmacro %}{{ greet("Bob") }}', c),
    'Hi Bob!', 'macro define + call');
  Check(f.RenderString('{% macro tag(t) %}<b>{{ t }}</b>{% endmacro %}{{ tag(name) }}', c),
    '<b>Andre</b>', 'macro output is safe HTML');

  { tests (is / is not) }
  Check(f.RenderString('{% if name is defined %}y{% else %}n{% endif %}', c), 'y', 'is defined');
  Check(f.RenderString('{% if missing is defined %}y{% else %}n{% endif %}', c), 'n', 'is defined (missing)');
  Check(f.RenderString('{% if "" is empty %}e{% endif %}', c), 'e', 'is empty');
  Check(f.RenderString('{% if name is not empty %}ne{% endif %}', c), 'ne', 'is not empty');
  Check(f.RenderString('{% if 4 is even %}ev{% endif %}{% if 3 is odd %}od{% endif %}', c), 'evod', 'is even/odd');
  Check(f.RenderString('{% if items is iterable %}it{% endif %}', c), 'it', 'is iterable');

  { parent() inside an overridden block }
  Check(f.RenderString('{% extends "base.twig" %}{% block body %}[{{ parent() }}]{% endblock %}', c),
    'BASE[[default]]', 'parent() in override');

  { import / from a macro file }
  WriteRaw(dir + '/macros.twig', '{% macro input(n) %}<input name="{{ n }}">{% endmacro %}');
  Check(f.RenderString('{% import "macros.twig" as forms %}{{ forms.input("email") }}', c),
    '<input name="email">', 'import as ns + call');
  Check(f.RenderString('{% from "macros.twig" import input %}{{ input("q") }}', c),
    '<input name="q">', 'from import + call');

  { cache — same key returns the first render even if context changes }
  c.Delete('v'); c.Add('v', 'one');
  Check(f.RenderString('{% cache "k1" 60 %}{{ v }}{% endcache %}', c), 'one', 'cache first render');
  c.Delete('v'); c.Add('v', 'two');
  Check(f.RenderString('{% cache "k1" 60 %}{{ v }}{% endcache %}', c), 'one', 'cache returns stored');

  c.Free; f.Free;
  Writeln;
  Writeln(Passed, ' assertions passed, ', Failed, ' failed.');
  if Failed = 0 then begin Writeln('ALL TESTS PASS'); Halt(0); end else Halt(1);
end.
