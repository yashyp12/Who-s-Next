import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../site/src/app.mjs', import.meta.url), 'utf8');
const css = await readFile(new URL('../site/src/styles.css', import.meta.url), 'utf8');
const html = await readFile(new URL('../site/index.html', import.meta.url), 'utf8');

test('team availability uses the document as its vertical scroll container', () => {
  const start = app.indexOf('<section class="panel team-panel"');
  const end = app.indexOf('</section>', start);
  const markup = app.slice(start, end);
  assert.match(markup, /class="table-wrap"/);
  assert.doesNotMatch(markup, /table-wrap-vertical/);
  assert.match(markup, /aria-label="Team availability roster"/);
});

test('large rosters and report tables have no fixed-height nested scroll cap', () => {
  assert.doesNotMatch(css, /max-height:\s*min\(\d+px,/);
  assert.match(css, /\.table-wrap-vertical\s*\{[^}]*max-height:none/s);
  assert.match(css, /\.report-table-wrap\.table-wrap-vertical\s*\{[^}]*max-height:none/s);
  assert.doesNotMatch(app, /table-wrap-vertical/);
});

test('wide tables retain horizontal overflow while expanding to their full row height', () => {
  assert.match(css, /\.table-wrap\{overflow:auto\}/);
  assert.doesNotMatch(css, /\.table-wrap\s*\{[^}]*max-height:/s);
});

test('page-level horizontal overflow is clipped without disabling vertical document scrolling', () => {
  assert.match(css, /html, body\s*\{[^}]*overflow-x:clip/s);
  assert.match(css, /html, body\s*\{[^}]*overflow-y:auto/s);
  assert.match(css, /\.layout\s*\{[^}]*grid-template-columns:\s*248px minmax\(0,1fr\)/s);
  assert.match(css, /\.bottom-grid\s*\{[^}]*grid-template-columns:\s*repeat\(2,minmax\(0,1fr\)\)/s);
  assert.match(css, /\.main, \.section-view\s*\{[^}]*min-width:\s*0/s);
});

test('responsive header and shift toolbar avoid horizontal collisions', () => {
  assert.match(css, /\.topbar\s*\{[^}]*grid-template-columns:minmax\(170px,220px\) minmax\(0,1fr\)/s);
  assert.match(css, /\.schedule-toolbar-actions\s*\{[^}]*flex-wrap:nowrap/s);
  assert.match(css, /@media\(max-width:900px\)/);
  assert.match(css, /@media\(max-width:720px\)/);
});

test('frontend asset URLs are cache-busted for the responsive layout fix', () => {
  assert.match(html, /styles\.css\?v=20261109-responsive-analytics-v2/);
  assert.match(html, /app\.mjs\?v=20261109-responsive-analytics-v2/);
});
