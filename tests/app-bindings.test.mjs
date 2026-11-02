import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const appSource = await readFile(new URL('../site/src/app.mjs', import.meta.url), 'utf8');
const cssSource = await readFile(new URL('../site/src/styles.css', import.meta.url), 'utf8');
const bindingSource = appSource.match(/function bindViewActions\(\) \{([\s\S]*?)\n\}/)?.[1];

test('admin controls use plural selectors before iterating', () => {
  assert.ok(bindingSource, 'bindViewActions must exist');
  for (const selector of ['[data-admin-rotate]', '[data-admin-toggle]', '[data-admin-name]', '[data-admin-shift]']) {
    assert.match(bindingSource, new RegExp('\\$\\$\\(' + JSON.stringify(selector).replace(/[.*+?^${}()|[\\]\\\\]/g, '\\$&') + '\\)\\.forEach'));
    assert.doesNotMatch(bindingSource, new RegExp('(?<!\\$)\\$\\(' + JSON.stringify(selector).replace(/[.*+?^${}()|[\\]\\\\]/g, '\\$&') + '\\)\\.forEach'));
  }
});

test('controls duplicated in hidden and active views bind every matching element', () => {
  assert.ok(bindingSource, 'bindViewActions must exist');
  for (const selector of ['#take-over', '#record-next', '#add-break', '#set-shift']) {
    assert.match(bindingSource, new RegExp('\\$\\$\\(' + JSON.stringify(selector).replace(/[.*+?^${}()|[\\]\\\\]/g, '\\$&') + '\\)\\.forEach'));
  }
});

test('mobile admin navigation has six columns and top actions can wrap', () => {
  assert.match(cssSource, /\.nav:has\(button\[data-view="admin"\]\)[\s\S]*?grid-template-columns:\s*repeat\(6,/);
  assert.match(cssSource, /\.top-actions\s*\{[^}]*flex-wrap:\s*wrap/s);
});
