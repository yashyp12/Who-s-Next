import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../site/src/app.mjs', import.meta.url), 'utf8');
const css = await readFile(new URL('../site/src/styles.css', import.meta.url), 'utf8');
const html = await readFile(new URL('../site/index.html', import.meta.url), 'utf8');

test('monthly analytics validates a real YYYY-MM value instead of a literal backslash sequence', () => {
  assert.ok(app.includes('!/^\\d{4}-\\d{2}$/.test(month)'), 'month guard must use digit classes');
  assert.ok(!app.includes('!/^\\\\d{4}-\\\\d{2}$/.test(month)'), 'month guard must not expect literal backslashes');
});

test('monthly analytics cannot remain in a loading state forever', () => {
  assert.match(app, /adminAnalyticsLoading\s*=\s*true/);
  assert.match(app, /adminAnalyticsLoading\s*=\s*false/);
  assert.match(app, /Promise\.race\s*\(/);
  assert.match(app, /15000/);
  assert.match(app, /analytics-retry/);
  assert.match(app, /analytics-error-state/);
});

test('desktop header uses distinct grid tracks for title, clock and actions', () => {
  assert.match(css, /\.topbar\s*\{[^}]*display:\s*grid/s);
  assert.match(css, /grid-template-columns:\s*minmax\(0,1fr\)\s+max-content\s+minmax\(0,max-content\)/);
  assert.match(css, /@media\s*\(max-width:\s*1320px\)/);
  assert.match(css, /@media\s*\(max-width:\s*720px\)/);
  assert.match(css, /\.digital-clock\s*\{[^}]*flex:\s*none/s);
});

test('reports states are structured and accessible rather than bare loading text', () => {
  assert.match(app, /role="status" aria-live="polite"/);
  assert.match(app, /role="alert"/);
  assert.match(app, /Preparing your monthly report/);
  assert.match(app, /We couldn’t load this report/);
  assert.match(css, /\.analytics-state-card\s*\{/);
});

test('static asset versions are refreshed for the layout and report fix', () => {
  assert.match(html, /styles\.css\?v=20261109-header-reports-fix/);
  assert.match(html, /app\.mjs\?v=20261109-header-reports-fix/);
});
