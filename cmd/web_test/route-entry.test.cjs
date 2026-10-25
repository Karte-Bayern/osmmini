const assert = require('node:assert/strict');
const { test } = require('node:test');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');

const source = readFileSync(join(__dirname, '../web/app.js'), 'utf8');
const start = source.indexOf("makeSuggest('from-suggest','from');");
const end = source.indexOf('\nconst SEARCH_SOURCE_ID', start);
assert.ok(start >= 0 && end > start, 'route input handlers are available');

class Element extends EventTarget {
  constructor(id = '') {
    super();
    this.id = id;
    this.value = '';
    this.children = [];
    this.style = {};
    this.dataset = {};
    this.attributes = {};
    this.classList = { toggle() {} };
  }
  setAttribute(key, value) { this.attributes[key] = String(value); }
  removeAttribute(key) { delete this.attributes[key]; }
  appendChild(child) { this.children.push(child); }
  set innerHTML(value) { this.children = []; this.html = value; }
  get innerHTML() { return this.html || (this.children.length ? '<children>' : ''); }
  querySelectorAll() { return this.children.filter(child => child.attributes.role === 'option'); }
  querySelector() { return null; }
  contains(target) { return this === target || this.children.some(child => child.contains(target)); }
  focus() { this.focuses = (this.focuses || 0) + 1; }
  blur() { this.blurs = (this.blurs || 0) + 1; }
  remove() { this.removed = true; }
  click() { this.onclick?.(); }
}

function harness() {
  const elements = Object.fromEntries(['from', 'to', 'from-suggest', 'to-suggest', 'waypointsContainer', 'placeSearch', 'mapWelcomeOverlay'].map(id => [id, new Element(id)]));
  elements.mapWelcomeOverlay.hidden = true;
  function find(id, element) {
    if (element.id === id) return element;
    for (const child of element.children) {
      const match = find(id, child);
      if (match) return match;
    }
  }
  const document = new Element();
  document.getElementById = id => elements[id] || find(id, elements.waypointsContainer);
  document.createElement = () => new Element();
  const timers = new Map();
  let nextTimer = 0, computes = 0, scheduled = 0;
  let searchResults = [];
  const waypoints = [];
  const views = [];
  const context = vm.createContext({
    document, waypoints, waypointSeq: 1, AbortController,
    compute() { computes++; },
    setMapsView(view) { views.push(view); },
    debouncedCompute() { scheduled++; },
    cancelRouteComputation() {}, clearRouteLocationChoices() {},
    setTimeout(fn) { timers.set(++nextTimer, fn); return nextTimer; },
    clearTimeout(id) { timers.delete(id); },
    fetch: async () => ({ ok: true, json: async () => searchResults }),
    applySearchResultToInput(input, result) { input.value = result.label; return true; },
    getResultPrimary: result => result.label, getResultSecondary: () => '',
    highlight: value => value, escapeHtml: value => value,
    showSearchResultsOnMap() {}, showToast() {},
  });
  vm.runInContext(source.slice(start, end), context);
  const shortcutsStart = source.indexOf('// keyboard shortcuts');
  const shortcutsEnd = source.indexOf('// Emergency mode change handler', shortcutsStart);
  assert.ok(shortcutsStart >= 0 && shortcutsEnd > shortcutsStart);
  vm.runInContext(source.slice(shortcutsStart, shortcutsEnd), context);
  const searchShortcutEnd = source.indexOf('// Drawing shares the map click handler');
  const searchShortcutStart = source.lastIndexOf("document.addEventListener('keydown', event => {", searchShortcutEnd);
  assert.ok(searchShortcutStart >= 0 && searchShortcutEnd > searchShortcutStart);
  vm.runInContext(source.slice(searchShortcutStart, searchShortcutEnd), context);
  return {
    elements, context, waypoints, views,
    get computes() { return computes; },
    get scheduled() { return scheduled; },
    add() { context.addWaypoint(); return waypoints.at(-1); },
    key(input, key, properties = {}, bubble = false) {
      const event = new Event('keydown', { cancelable: true });
      Object.assign(event, { key, ...properties });
      if (properties.alreadyHandled) event.preventDefault();
      document.activeElement = input;
      input.dispatchEvent(event);
      if (bubble) document.dispatchEvent(event);
      return event;
    },
    suggestions(input) { return document.getElementById(input.attributes['aria-controls']); },
    async search(input, results = [{ label: 'Passau', lat: 48.57, lon: 13.45 }]) {
      searchResults = results;
      input.value = 'Pass';
      input.dispatchEvent(new Event('input'));
      const callbacks = [...timers.values()];
      timers.clear();
      await Promise.all(callbacks.map(fn => fn()));
    },
  };
}

test('Enter submits exactly once from Start, Ziel and a waypoint', () => {
  const h = harness();
  for (const [index, input] of [h.elements.from, h.elements.to, h.add().input].entries()) {
    input.value = 'Passau';
    assert.equal(h.key(input, 'Enter').defaultPrevented, true);
    assert.equal(h.computes, index + 1);
  }
});

test('Enter selects a highlighted suggestion before a later Enter submits the route', async () => {
  const h = harness();
  for (const [index, input] of [h.elements.from, h.elements.to, h.add().input].entries()) {
    await h.search(input);
    h.key(input, 'ArrowDown');
    assert.equal(h.key(input, 'Enter').defaultPrevented, true);
    assert.equal(input.value, 'Passau');
    assert.equal(h.computes, index);
    h.key(input, 'Enter');
    assert.equal(h.computes, index + 1);
  }
});

test('IME confirmation leaves both suggestion selection and route submission untouched', async () => {
  const h = harness();
  for (const input of [h.elements.from, h.elements.to, h.add().input]) {
    await h.search(input);
    h.key(input, 'ArrowDown');
    for (const properties of [{ isComposing: true }, { keyCode: 229 }]) {
      assert.equal(h.key(input, 'Enter', properties).defaultPrevented, false);
      assert.equal(input.value, 'Pass');
      assert.equal(input.attributes['aria-expanded'], 'true');
      assert.equal(h.computes, 0);
    }
  }
});

test('repeated Enter and modified shortcuts do not submit through the field handler', () => {
  const h = harness();
  for (const input of [h.elements.from, h.elements.to, h.add().input]) {
    for (const properties of [{ repeat: true }, { ctrlKey: true }, { metaKey: true }, { altKey: true }]) {
      assert.equal(h.key(input, 'Enter', properties).defaultPrevented, false);
    }
  }
  assert.equal(h.computes, 0);
});

test('removing an empty waypoint only removes the row; populated stops still recalculate', () => {
  const h = harness();
  for (const value of ['', '   ']) {
    const waypoint = h.add();
    waypoint.input.value = value;
    h.context.removeWaypoint(waypoint.id);
    assert.equal(waypoint.wrapper.removed, true);
    assert.equal(h.waypoints.length, 0);
    assert.equal(h.computes, 0);
  }
  const filled = h.add();
  filled.input.value = 'Passau';
  h.context.removeWaypoint(filled.id);
  assert.equal(h.computes, 1);
  const batch = h.add();
  batch.input.value = 'Landshut';
  h.context.removeWaypoint(batch.id, false);
  h.context.removeWaypoint('missing');
  assert.equal(h.computes, 1);
});

test('waypoint edits and programmatic additions retain their debounced calculation', () => {
  const h = harness();
  const waypoint = h.add();
  waypoint.input.value = 'Passau';
  waypoint.input.dispatchEvent(new Event('change'));
  assert.equal(h.scheduled, 1);
  h.context.addWaypointWithValue('Landshut');
  assert.equal(h.scheduled, 2);
  assert.equal(h.waypoints.at(-1).input.value, 'Landshut');
});

test('Escape closes suggestions without blurring the input through a global shortcut', async () => {
  const h = harness();
  for (const input of [h.elements.from, h.elements.to, h.add().input]) {
    await h.search(input);
    assert.equal(h.key(input, 'Escape', {}, true).defaultPrevented, true);
    assert.equal(input.attributes['aria-expanded'], 'false');
    assert.equal(input.blurs || 0, 0);
    assert.equal(h.key(input, 'Escape', {}, true).defaultPrevented, false);
    assert.equal(input.blurs, 1);
  }
});

test('an empty search is explained without creating a selectable option', async () => {
  const h = harness();
  const input = h.elements.to;
  await h.search(input, []);
  const container = h.suggestions(input);
  assert.equal(input.attributes['aria-expanded'], 'true');
  assert.equal(container.children.length, 1);
  assert.equal(container.children[0].attributes.role, 'status');
  assert.match(container.children[0].textContent, /Keine Vorschläge/);
  assert.equal(container.children[0].onclick, undefined);
  assert.equal(h.key(input, 'ArrowDown').defaultPrevented, false);
  assert.equal(input.attributes['aria-activedescendant'], undefined);
  h.key(input, 'Enter', {}, true);
  assert.equal(h.computes, 1, 'Enter submits the typed route instead of selecting the status message');
  assert.equal(input.value, 'Pass');
});

test('Ctrl/Cmd+K opens discovery once without focusing the hidden route input', () => {
  for (const modifier of ['ctrlKey', 'metaKey']) {
    const h = harness();
    assert.equal(h.key(h.elements.to, 'k', { [modifier]: true }, true).defaultPrevented, true);
    assert.deepEqual(h.views, ['explore']);
    assert.equal(h.elements.placeSearch.focuses, 1);
    assert.equal(h.elements.from.focuses || 0, 0);
    assert.equal(h.computes, 0);
    h.elements.mapWelcomeOverlay.hidden = false;
    h.key(h.elements.to, 'k', { [modifier]: true }, true);
    assert.equal(h.views.length, 1, 'the welcome flow keeps control of focus');
  }
});

test('global shortcuts respect consumed events and IME composition', () => {
  const h = harness();
  for (const properties of [{ alreadyHandled: true }, { isComposing: true }, { keyCode: 229 }]) {
    h.key(h.elements.from, 'Enter', { ctrlKey: true, ...properties }, true);
    h.key(h.elements.from, 'k', { ctrlKey: true, ...properties }, true);
    h.key(h.elements.from, 'Escape', properties, true);
  }
  assert.equal(h.computes, 0);
  assert.equal(h.views.length, 0);
  assert.equal(h.elements.from.blurs || 0, 0);
  h.key(h.elements.from, 'Enter', { ctrlKey: true }, true);
  assert.equal(h.computes, 1, 'unconsumed Ctrl+Enter still computes once');
});
