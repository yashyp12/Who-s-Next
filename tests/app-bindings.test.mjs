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
