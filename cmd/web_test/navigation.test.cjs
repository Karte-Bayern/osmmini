const assert = require('node:assert/strict');
const { test } = require('node:test');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');

const source = readFileSync(join(__dirname, '../web/app.js'), 'utf8');
const start = source.indexOf('function syncMapsNavigation()');
const end = source.indexOf("\nif (typeof ResizeObserver", start);
assert.ok(start >= 0 && end > start, 'navigation synchronizer source is available');

function harness(view, width, initialTitle = 'Ansicht') {
  const shell = { dataset: { view } };
  const title = { textContent: initialTitle };
  const buttons = ['explore', 'route', 'assistant', 'maps', 'edit', 'tools'].map(mapView => ({
    dataset: { mapView },
    attributes: {},
    setAttribute(key, value) { this.attributes[key] = String(value); },
  }));
  const window = { innerWidth: width };
  const context = vm.createContext({
    window,
    document: {
      querySelector: selector => selector === '.maps-shell' ? shell : null,
      querySelectorAll: selector => selector === '.maps-rail [data-map-view]' ? buttons : [],
      getElementById: id => id === 'mapsPanelTitle' ? title : null,
    },
  });
  vm.runInContext(source.slice(start, end), context);
  return {
    shell, title, window, buttons,
    sync: () => context.syncMapsNavigation(),
    visibleSelected: () => buttons.filter(button => button.attributes['aria-pressed'] === 'true'
      && (window.innerWidth > 768 || !['maps', 'edit'].includes(button.dataset.mapView)))
      .map(button => button.dataset.mapView),
  };
}

test('mobile maps and editing select the visible More tab and retain their own panel title', () => {
  for (const [view, title] of [['maps', 'Kartenebenen'], ['edit', 'OSM-Edit']]) {
    for (const width of [320, 390, 768]) {
      const h = harness(view, width, title);
      h.sync();
      assert.deepEqual(h.visibleSelected(), ['tools']);
      assert.equal(h.title.textContent, title);
    }
  }
});

test('desktop maps and editing select their own tab without selecting Tools', () => {
  for (const view of ['maps', 'edit']) {
    for (const width of [769, 1440]) {
      const h = harness(view, width);
      h.sync();
      assert.deepEqual(h.visibleSelected(), [view]);
      assert.equal(h.buttons.find(button => button.dataset.mapView === 'tools').attributes['aria-pressed'], 'false');
    }
  }
});

test('Tools title follows the viewport in both directions without changing the current view', () => {
  const h = harness('tools', 768);
  h.sync();
  assert.equal(h.title.textContent, 'Mehr');
  h.window.innerWidth = 769;
  h.sync();
  assert.equal(h.title.textContent, 'Werkzeuge');
  h.window.innerWidth = 390;
  h.sync();
  assert.equal(h.title.textContent, 'Mehr');
  assert.equal(h.shell.dataset.view, 'tools');
  assert.deepEqual(h.visibleSelected(), ['tools']);
});

test('changing views or crossing the breakpoint clears stale selected tabs', () => {
  const h = harness('maps', 390, 'Kartenebenen');
  h.sync();
  assert.deepEqual(h.visibleSelected(), ['tools']);
  h.window.innerWidth = 1024;
  h.sync();
  assert.deepEqual(h.visibleSelected(), ['maps']);
  for (const view of ['explore', 'route', 'assistant', 'tools']) {
    h.shell.dataset.view = view;
    for (const width of [390, 1024]) {
      h.window.innerWidth = width;
      h.sync();
      assert.deepEqual(h.visibleSelected(), [view]);
      assert.equal(h.buttons.filter(button => button.attributes['aria-pressed'] === 'true').length, 1);
    }
  }
});

function clickHarness({ currentView = 'explore', route = null } = {}) {
  const shell = { dataset: { view: currentView } };
  const calls = [];
  const buttons = ['route', 'maps', 'more-maps'].map(name => {
    const button = new EventTarget();
    button.name = name;
    button.dataset = { mapView: name === 'more-maps' ? 'maps' : name };
    button.closest = selector => name === 'more-maps' && selector === '.maps-more-destinations' ? {} : null;
    return button;
  });
  const elements = Object.fromEntries(['from', 'aiPrompt', 'placeSearch', 'mapsPanelBack'].map(id => [id, {
    focus: () => calls.push(`focus:${id}`),
  }]));
  elements.mapsLayers = { click() { calls.push('layers'); shell.dataset.view = 'maps'; } };
  const context = vm.createContext({
    currentRouteMeta: route,
    setMapsView(view) { calls.push(`view:${view}`); shell.dataset.view = view; },
    document: {
      querySelector: selector => selector === '.maps-shell' ? shell : null,
      querySelectorAll: selector => selector === '[data-map-view]' ? buttons : [],
      getElementById: id => elements[id],
    },
  });
  const listenerStart = source.indexOf("document.querySelectorAll('[data-map-view]').forEach(button => {");
  const listenerEnd = source.indexOf("\ndocument.getElementById('mapsLayers')?.addEventListener", listenerStart);
  assert.ok(listenerStart >= 0 && listenerEnd > listenerStart, 'view navigation click listener is available');
  vm.runInContext(source.slice(listenerStart, listenerEnd), context);
  return {
    calls, context,
    click(name) { buttons.find(button => button.name === name).dispatchEvent(new Event('click')); },
  };
}

test('opening an existing route preserves the result overview without focusing the start input', () => {
  const h = clickHarness({ route: { distance_m: 1000, duration_s: 120 } });
  h.click('route');
  assert.deepEqual(h.calls, ['view:route']);
});

test('opening an empty route focuses Start and reads route state when clicked', () => {
  const h = clickHarness({ route: { distance_m: 1000, duration_s: 120 } });
  h.context.currentRouteMeta = null;
  h.click('route');
  assert.deepEqual(h.calls, ['view:route', 'focus:from']);
});

test('map links use the layers return path and focus Back only when opened from More', () => {
  const more = clickHarness({ currentView: 'tools' });
  more.click('more-maps');
  assert.deepEqual(more.calls, ['layers', 'focus:mapsPanelBack']);
  const rail = clickHarness({ currentView: 'route' });
  rail.click('maps');
  assert.deepEqual(rail.calls, ['layers']);
});
