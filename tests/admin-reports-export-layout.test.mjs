import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../site/src/app.mjs', import.meta.url), 'utf8');
const css = await readFile(new URL('../site/src/styles.css', import.meta.url), 'utf8');
const html = await readFile(new URL('../site/index.html', import.meta.url), 'utf8');

test('admin reports provide separate agent-performance and allocation-history CSV exports', () => {
  assert.match(app, /function exportAgentPerformanceCsv/);
  assert.match(app, /function exportMonthlyAllocationCsv/);
  assert.match(app, /id="export-agent-csv"/);
  assert.match(app, /id="export-month-csv"/);
  assert.match(app, /Rank.*Agent.*Total allocations.*New emails.*Existing tickets/s);
  assert.match(app, /Work date.*Assigned at.*Recipient.*Assigned by.*Reference.*Subject.*Allocation type/s);
  assert.match(app, /export-agent-csv.*exportAgentPerformanceCsv/);
  assert.match(app, /export-month-csv.*exportMonthlyAllocationCsv/);
});

test('agent report ranks by allocation count and only describes measurable workload', () => {
  assert.match(app, /Number\(b\.count\) - Number\(a\.count\)/);
  assert.match(app, /Share of monthly allocations/);
  assert.match(app, /They do not represent ticket resolution, quality scores or SLA completion/);
  assert.match(app, /Number\(item\.newEmails\)/);
  assert.match(app, /Number\(item\.existingTickets\)/);
});

test('CSV export is UTF-8 compatible and protects against spreadsheet formula injection', () => {
  assert.match(app, /join\('\\r\\n'\)/);
  assert.match(app, /new Blob\(\['\\uFEFF', csv\]/);
  assert.match(app, /\^\[\\t\\r\\n \]\*\[=\\+\\-@\]/);
  assert.match(app, /replace\(\/"\/g, '""'\)/);
});

test('reports month picker is compact and has responsive report layout', () => {
  assert.match(app, /class="report-period-control"/);
  assert.match(css, /\.report-period-control\s*\{/);
  assert.match(css, /#analytics-month\s*\{[^}]*width:190px/s);
  assert.match(css, /@media\(max-width:720px\)/);
  assert.match(css, /\.reports-heading\s*\{[^}]*grid-template-columns:minmax\(0,1fr\) auto/s);
});

test('workspace clock and actions occupy separate predictable header tracks', () => {
  assert.match(css, /\.topbar\s*\{[^}]*grid-template-columns:minmax\(0,1fr\) minmax\(0,1fr\)/s);
  assert.match(css, /\.topbar-title-wrap\s*\{[^}]*grid-column:1 \/ -1/s);
  assert.match(css, /\.digital-clock\s*\{[^}]*grid-row:2/s);
  assert.match(css, /\.top-actions\s*\{[^}]*grid-row:2/s);
});

test('long report tables scroll only when their row count exceeds the threshold', () => {
  assert.match(app, /members\.length > 8 \? ' table-wrap-vertical'/);
  assert.match(app, /records\.length > 8 \? ' table-wrap-vertical'/);
  assert.match(css, /\.report-table-wrap\.table-wrap-vertical\s*\{[^}]*overflow:auto/s);
  assert.match(css, /\.report-table th\s*\{[^}]*position:sticky/s);
});

test('report asset cache versions are refreshed', () => {
  assert.match(html, /styles\.css\?v=20261109-admin-reports-v2/);
  assert.match(html, /app\.mjs\?v=20261109-admin-reports-v2/);
});
