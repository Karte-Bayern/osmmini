const assert = require('node:assert/strict');
const { test } = require('node:test');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');

const source = readFileSync(join(__dirname, '../web/app.js'), 'utf8');
const start = source.indexOf('function formatMeters(');
const end = source.indexOf("\ndocument.getElementById('go').addEventListener", start);
assert.ok(start >= 0 && end > start, 'maneuver renderer source is available');

class Element extends EventTarget {
  constructor(tagName) {
    super();
    this.tagName = tagName;
    this.children = [];
    this.attributes = {};
    this.style = {};
    this.textContent = '';
  }
  setAttribute(key, value) { this.attributes[key] = String(value); }
  set innerHTML(value) { this.children = []; this.html = value; }
  get innerHTML() { return this.html || ''; }
  append(...children) { this.children.push(...children); }
  appendChild(child) { this.children.push(child); return child; }
}

function harness() {
  const container = new Element('div');
  const pans = [];
  const context = vm.createContext({
    document: {
      getElementById: () => container,
      createElement: tagName => new Element(tagName),
    },
    map: { panTo: point => pans.push(Array.from(point)) },
  });
  vm.runInContext(source.slice(start, end), context);
  return {
    container, pans,
    render: steps => context.renderManeuvers(steps),
    icon: type => context.iconForType(type),
    rows: () => container.children[0]?.children || [],
  };
}

function find(element, className) {
  if ((element.className || '').split(' ').includes(className)) return element;
  for (const child of element.children) {
    const found = find(child, className);
    if (found) return found;
  }
}

test('zero coordinates produce an accessible native button and pan correctly', () => {
  const h = harness();
  h.render([{ type: 'turn-left', lat: 0, lon: 0, distance_m: 120, duration_s: 12 }]);
  const [row] = h.rows();
  assert.equal(row.tagName, 'button');
  assert.equal(row.type, 'button');
  assert.equal(row.attributes['aria-label'], 'Links abbiegen · 120 m · < 1 min · Auf Karte anzeigen');
  assert.equal(find(row, 'maneuver-instr').textContent, 'Links abbiegen');
  assert.equal(find(row, 'maneuver-type'), undefined);
  row.dispatchEvent(new Event('click'));
  assert.deepEqual(h.pans, [[0, 0]]);
});

test('missing, nonnumeric, nonfinite and out-of-range coordinates stay noninteractive', () => {
  const h = harness();
  const invalid = [
    {}, { lat: null, lon: 12 }, { lat: '', lon: 12 }, { lat: '48', lon: '12' },
    { lat: NaN, lon: 12 }, { lat: 48, lon: Infinity }, { lat: 91, lon: 12 }, { lat: 48, lon: -181 },
  ];
  h.render(invalid);
  for (const row of h.rows()) {
    assert.equal(row.tagName, 'div');
    assert.equal(row.attributes['aria-label'], undefined);
    assert.equal(row.attributes.tabindex, undefined);
    assert.equal(row.attributes.role, undefined);
    row.dispatchEvent(new Event('click'));
  }
  assert.equal(h.pans.length, 0);
});

test('legacy field names are supported without replacing lowercase zero coordinates', () => {
  const h = harness();
  h.render([
    { Type: 'turn-right', Instruction: 'Rechts in die Bahnhofstraße', Lat: -90, Lon: 180, DistanceM: 1500, DurationS: 120 },
    { type: 'depart', lat: 0, lon: 0, Lat: 48, Lon: 12 },
  ]);
  const [legacy, zero] = h.rows();
  assert.equal(find(legacy, 'maneuver-instr').textContent, 'Rechts in die Bahnhofstraße');
  assert.equal(find(legacy, 'maneuver-dist').textContent, '1.5 km');
  assert.equal(find(legacy, 'maneuver-dur').textContent, '2 min');
  legacy.dispatchEvent(new Event('click'));
  zero.dispatchEvent(new Event('click'));
  assert.deepEqual(h.pans, [[180, -90], [0, 0]]);
});

test('arrival omits empty metrics and untrusted instruction text is never parsed as HTML', () => {
  const h = harness();
  const instruction = '<img src=x onerror=alert(1)> Ziel erreicht';
  h.render([{ type: 'arrive', instruction, lat: 48, lon: 12, distance_m: 0, duration_s: 0 }]);
  const [row] = h.rows();
  const text = find(row, 'maneuver-instr');
  assert.equal(text.textContent, instruction);
  assert.equal(text.innerHTML, '');
  assert.equal(find(row, 'maneuver-right'), undefined);
  assert.equal(row.attributes['aria-label'], `${instruction} · Auf Karte anzeigen`);
});

test('empty and unknown instructions receive short German fallbacks with decorative SVGs', () => {
  const h = harness();
  const types = ['turn-left', 'turn-right', 'uturn', 'depart', 'arrive', 'continue', 'turn', 'unknown', '__proto__'];
  const labels = ['Links abbiegen', 'Rechts abbiegen', 'Wenden', 'Losfahren', 'Ziel erreicht', 'Geradeaus weiter', 'Abbiegen', 'Route folgen', 'Route folgen'];
  h.render(types.map(type => ({ type, instruction: '   ' })));
  h.rows().forEach((row, i) => {
    assert.equal(find(row, 'maneuver-instr').textContent, labels[i]);
    const icon = find(row, 'maneuver-icon').innerHTML;
    assert.match(icon, /^<svg /);
    assert.match(icon, /stroke="currentColor"/);
    assert.match(icon, /aria-hidden="true"/);
    assert.match(icon, /focusable="false"/);
    assert.doesNotMatch(icon, /undefined|\[object/);
  });
});

test('replacing directions clears stale rows, and empty or malformed data hides the section', () => {
  const h = harness();
  h.render([{ type: 'depart' }, { type: 'arrive' }]);
  assert.equal(h.rows().length, 2);
  h.render([null, undefined, 'invalid', { type: 'arrive' }]);
  assert.equal(h.rows().length, 1);
  assert.equal(h.container.style.display, 'block');
  for (const steps of [[], null, {}, [null]]) {
    h.render(steps);
    assert.equal(h.rows().length, 0);
    assert.equal(h.container.style.display, 'none');
  }
});
