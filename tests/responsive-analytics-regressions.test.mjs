import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../site/src/app.mjs', import.meta.url), 'utf8');
const css = await readFile(new URL('../site/src/styles.css', import.meta.url), 'utf8');
const html = await readFile(new URL('../site/index.html', import.meta.url), 'utf8');

test('admin analytics puts the daily trend and allocation mix on one responsive row', () => {
  assert.match(app, /class="analytics-trend-panel"/);
  assert.doesNotMatch(app, /class="panel analytics-wide"/);
  assert.match(css, /\.reports-insights\s*\{[^}]*grid-template-columns:minmax\(0,1\.7fr\) minmax\(260px,\.8fr\)/s);
  assert.match(css, /@media\(max-width:900px\)/);
});

test('analytics supports daily and weekly trend grouping plus agent and work-type table filters', () => {
  assert.match(app, /id="analytics-granularity"/);
  assert.match(app, /id="analytics-agent-filter"/);
  assert.match(app, /id="analytics-kind-filter"/);
  assert.match(app, /function analyticsDaysForView/);
  assert.match(app, /adminAnalyticsAgentFilter/);
  assert.match(app, /adminAnalyticsKindFilter/);
});

test('Excel export creates a dashboard, agent and allocation history sheets with embedded chart images', () => {
  assert.match(app, /async function exportAdminAnalyticsExcel/);
  assert.match(app, /exceljs@4\.4\.0/);
  assert.match(app, /addWorksheet\('Dashboard'/);
  assert.match(app, /addWorksheet\('Agent performance'/);
  assert.match(app, /addWorksheet\('Allocation history'/);
  assert.match(app, /workbook\.addImage/);
  assert.match(app, /workbook\.xlsx\.writeBuffer/);
  assert.match(app, /export-analytics-xlsx/);
});

test('set shift, add break and request swap remain on one line at desktop widths', () => {
  assert.match(app, /schedule-toolbar-actions/);
  assert.match(css, /\.schedule-toolbar-actions\s*\{[^}]*flex-wrap:nowrap/s);
  assert.match(css, /@media\(max-width:720px\)/);
});

test('frontend assets use the responsive analytics cache version', () => {
  assert.match(html, /styles\.css\?v=20261109-responsive-analytics-v2/);
  assert.match(html, /app\.mjs\?v=20261109-responsive-analytics-v2/);
});
