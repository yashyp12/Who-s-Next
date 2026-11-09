import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const css = await readFile(new URL('../site/src/styles.css', import.meta.url), 'utf8');
const app = await readFile(new URL('../site/src/app.mjs', import.meta.url), 'utf8');

test('workspace keeps the existing navigation and server-controlled admin access', () => {
  assert.match(app, /currentIsAdmin\s*\?\s*navButton\('admin'/);
  assert.match(app, /currentIsAdmin\s*=\s*Boolean\(me\?\.is_admin\)/);
  assert.match(app, /id="view-admin"/);
});

test('topbar wraps cleanly without overlapping the clock or tour action', () => {
  assert.match(css, /\.topbar\s*\{[^}]*flex-wrap:\s*wrap/s);
  assert.match(css, /\.top-actions\s*\{[^}]*flex-wrap:\s*wrap/s);
  assert.match(css, /#tour-replay\s*\{[^}]*flex:\s*0\s+0\s+auto/s);
});

test('guided tour retains its original centered presentation', () => {
  assert.match(css, /\.intro-tour-backdrop\s*\{[^}]*background:\s*rgba\(4,\s*8,\s*13,\s*\.78\)/s);
  assert.match(css, /\.intro-tour-card\s*\{[^}]*left:\s*50%/s);
  assert.match(css, /\.tour-target-active\s*\{[^}]*z-index:\s*10002/s);
});

test('long operational lists have contained scrolling and visible scrollbar styling', () => {
  for (const selector of ['.schedule-list', '.request-list', '.queue-list', '.activity-list', '.analytics-agent-list']) {
    assert.ok(css.includes(selector), `missing scroll styling for ${selector}`);
  }
  assert.match(css, /\.schedule-list,\.request-list,\.queue-list,\.activity-list,\.analytics-agent-list\s*\{[^}]*overflow-y:\s*auto/s);
  assert.match(css, /\.table-wrap\s*\{[^}]*overflow:\s*auto/s);
});

test('workspace prevents horizontal overflow while preserving the main content width', () => {
  assert.match(css, /\.layout\s*\{[^}]*overflow-x:\s*clip/s);
  assert.match(css, /\.main\s*\{[^}]*min-width:\s*0/s);
});
