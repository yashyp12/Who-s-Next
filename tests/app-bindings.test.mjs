import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const appSource = await readFile(new URL('../site/src/app.mjs', import.meta.url), 'utf8');
const cssSource = await readFile(new URL('../site/src/styles.css', import.meta.url), 'utf8');
const bindingSource = appSource.match(/function bindViewActions\(\) \{([\s\S]*?)\n\}/)?.[1];

test('navigation buttons are selected as a collection before iteration', () => {
  assert.ok(bindingSource, 'bindViewActions must exist');
  assert.ok(appSource.includes("$$('.nav button').forEach"), 'Navigation must use the plural selector helper');
  assert.doesNotMatch(appSource, /(?<!\$)\$\('.nav button'\)\.forEach/, 'Navigation must not iterate a single querySelector result');
});

test('admin control collections use querySelectorAll before iteration', () => {
  assert.ok(bindingSource, 'bindViewActions must exist');
  for (const selector of ['[data-admin-rotate]', '[data-admin-toggle]', '[data-admin-name]', '[data-admin-shift]']) {
    assert.ok(bindingSource.includes(`document.querySelectorAll('${selector}')`), `Expected a collection selector for ${selector}`);
  }
});

test('controls duplicated in hidden and active views bind every matching element', () => {
  assert.ok(bindingSource, 'bindViewActions must exist');
  for (const selector of ['#take-over', '#record-next', '#add-break', '#set-shift']) {
    assert.ok(bindingSource.includes(`document.querySelectorAll('${selector}')`), `Expected all matching controls for ${selector}`);
  }
});

test('mobile admin navigation has six columns and top actions can wrap', () => {
  assert.match(cssSource, /\.nav:has\(button\[data-view="admin"\]\)[\s\S]*?grid-template-columns:\s*repeat\(6,/);
  assert.match(cssSource, /\.top-actions\s*\{[^}]*flex-wrap:\s*wrap/s);
});

test('workspace includes persistent sidebar controls, sign-out and shift auto check-in', () => {
  assert.match(appSource, /id="sidebar-toggle"/);
  assert.match(appSource, /id="sign-out"/);
  assert.match(appSource, /await maybeAutoCheckIn\(\)/);
  assert.match(appSource, /record_attendance', \{ p_event_type: 'check_in' \}/);
});

test('allocation history separates recipient, assigner, time and ticket details', () => {
  for (const label of ['Recipient', 'Assigned by', 'Time', 'Ticket / subject']) {
    assert.ok(appSource.includes(label), `Missing allocation log field: ${label}`);
  }
  assert.match(appSource, /allocation-log-item/);
});

test('compact layout controls do not overflow and sidebar can collapse', () => {
  assert.match(cssSource, /\.layout\.sidebar-collapsed/);
  assert.match(cssSource, /\.allocation-log-item/);
  assert.match(cssSource, /\.toolbar-actions/);
});
