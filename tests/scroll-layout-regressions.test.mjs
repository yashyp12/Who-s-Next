import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../site/src/app.mjs', import.meta.url), 'utf8');
const css = await readFile(new URL('../site/src/styles.css', import.meta.url), 'utf8');
const html = await readFile(new URL('../site/index.html', import.meta.url), 'utf8');

test('team availability enables its own scroll region only when the roster exceeds eight members', () => {
  const start = app.indexOf('<section class="panel team-panel"');
  const end = app.indexOf('</section>', start);
  const markup = app.slice(start, end);
  assert.match(markup, /class="table-wrap\$\{statuses\.length > 8 \? ' table-wrap-vertical' : ''\}"/);
  assert.match(markup, /aria-label="Team availability roster"/);
  assert.match(markup, /tabindex="\$\{statuses\.length > 8 \? '0' : '-1'\}"/);
});

test('team roster scroll container keeps the column headings visible while scrolling rows', () => {
  assert.match(css, /\.table-wrap-vertical\s*\{[^}]*max-height:\s*min\(560px,62vh\)[^}]*overflow-y:\s*auto/s);
  assert.match(css, /\.table-wrap-vertical \.team-table thead\s*\{[^}]*position:\s*sticky[^}]*top:\s*0/s);
  assert.match(css, /@media\(max-width:720px\)\s*\{\s*\.table-wrap-vertical\s*\{\s*max-height:min\(460px,56vh\)/);
});

test('short team rosters do not receive a forced vertical scroll height', () => {
  assert.match(css, /\.table-wrap\s*\{[^}]*overflow-y:\s*visible/s);
  assert.doesNotMatch(css, /\.table-wrap\s*\{[^}]*max-height:/s);
});

test('page-level horizontal overflow is clipped without disabling vertical document scrolling', () => {
  assert.match(css, /html, body\s*\{[^}]*overflow-x:\s*clip/s);
  assert.match(css, /body\s*\{[^}]*overflow-y:\s*auto/s);
  assert.match(css, /\.layout\s*\{[^}]*grid-template-columns:\s*248px minmax\(0,1fr\)/s);
  assert.match(css, /\.bottom-grid\s*\{[^}]*grid-template-columns:\s*repeat\(2,minmax\(0,1fr\)\)/s);
  assert.match(css, /\.main, \.section-view\s*\{[^}]*min-width:\s*0/s);
});

test('frontend asset URLs are cache-busted for the scroll fix', () => {
  assert.match(html, /styles\.css\?v=20261109-admin-reports-v2/);
  assert.match(html, /app\.mjs\?v=20261109-admin-reports-v2/);
});
