import {
  SHIFT_PRESETS, REQUEST_TYPES, getMemberStatus, getEligibleMembers,
  recordAllocation, buildRotation, validateTimeRange, validateRequestPeriod, isBreakWithinShift, formatDuration,
} from './domain.mjs';
import { initializeNotificationCenter } from './notifications.mjs';

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const STORAGE_KEY = 'whos-next-demo-v1';
const PROFILE_KEY = 'whos-next-profile-v1';
const CONFIG = window.WHOS_NEXT_CONFIG || {};
const remoteConfigured = Boolean(CONFIG.supabaseUrl && CONFIG.supabaseAnonKey);
let supabase = null;
let remoteMode = false;
let state = null;
let activeView = 'allocation';
let currentMemberId = null;
let workspaceId = null;
let realtimeChannel = null;
let toastTimer = null;
let clockTimer = null;
let boundaryTimer = null;
let refreshInProgress = false;

const partsInTimezone = (date, timeZone) => { const parts = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(date); return Object.fromEntries(parts.filter((part) => part.type !== 'literal').map((part) => [part.type, part.value])); };
const partsInWorkspace = (date = new Date()) => partsInTimezone(date, state?.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone);
const localDate = (date = new Date()) => { const p = partsInWorkspace(date); return `${p.year}-${p.month}-${p.day}`; };
const localTime = (date = new Date()) => { const p = partsInWorkspace(date); return `${p.hour}:${p.minute}`; };
const localDateTime = (date = new Date()) => `${localDate(date)}T${localTime(date)}`;
const addMinutes = (date, minutes) => new Date(date.getTime() + minutes * 60000);
const escapeHtml = (value = '') => String(value).replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
const initials = (name = '') => name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0].toUpperCase()).join('') || '??';
const id = () => globalThis.crypto?.randomUUID?.() || `id-${Date.now()}-${Math.random().toString(16).slice(2)}`;
const statusFor = (member) => getMemberStatus(member, { now: new Date().toISOString(), date: localDate(), time: localTime() });
const prettyDate = (date) => new Intl.DateTimeFormat(undefined, { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' }).format(new Date(`${date}T12:00:00Z`));
const prettyTime = (value) => { if (!value) return '—'; const date = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/.test(value) ? new Date(workspaceInputToIso(value.slice(0, 16))) : new Date(value); return new Intl.DateTimeFormat(undefined, { timeZone: state?.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone, hour: '2-digit', minute: '2-digit' }).format(date); };
const prettyDateTime = (value) => value ? new Intl.DateTimeFormat(undefined, { timeZone: state?.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone, day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }).format(new Date(value)) : '—';
function workspaceInputToIso(value) {
  if (!value || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value)) throw new Error('Enter a valid date and time.');
  const [datePart, timePart] = value.split('T');
  const [year, month, day] = datePart.split('-').map(Number);
  const [hour, minute] = timePart.split(':').map(Number);
  const targetWallClock = Date.UTC(year, month - 1, day, hour, minute);
  const timeZone = state?.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone;
  let candidate = targetWallClock;
  for (let index = 0; index < 3; index += 1) {
    const parts = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(new Date(candidate));
    const values = Object.fromEntries(parts.filter((part) => part.type !== 'literal').map((part) => [part.type, Number(part.value)]));
    const representedWallClock = Date.UTC(values.year, values.month - 1, values.day, values.hour, values.minute);
    candidate += targetWallClock - representedWallClock;
  }
  return new Date(candidate).toISOString();
}
const escapeAttr = escapeHtml;

function demoSeed() {
  const now = new Date();
  const date = localDate(now);
  const minute = now.getHours() * 60 + now.getMinutes();
  const asClock = (n) => `${String(Math.floor(((n % 1440) + 1440) % 1440 / 60)).padStart(2, '0')}:${String(((n % 1440) + 1440) % 60).padStart(2, '0')}`;
  const members = Array.from({ length: 14 }, (_, index) => {
    const number = index + 1;
    const shiftKey = number <= 4 ? 'morning' : number <= 8 ? 'mid' : number <= 11 ? 'evening' : 'night';
    const preset = SHIFT_PRESETS[shiftKey];
    return { id: `member-${String(number).padStart(2, '0')}`, name: `Team Member ${String(number).padStart(2, '0')}`, active: true, sortOrder: number, shiftKey, shift: { date, key: shiftKey, start: preset.start, end: preset.end }, breaks: [], requests: [] };
  });
  const requests = [];
  const activeMember = members.find((m) => m.shiftKey === 'evening') || members[0];
  activeMember.breaks.push({ id: 'demo-break-1', date, start: asClock(minute - 8), end: asClock(minute + 17), note: 'Scheduled break' });
  const unavailableMember = members.find((m) => m.id === 'member-11');
  const start = addMinutes(now, -10);
  const end = addMinutes(now, 18);
  requests.push({ id: 'demo-request-1', memberId: unavailableMember.id, type: 'meeting', reason: 'Operations sync', details: 'Daily queue review', startAt: start.toISOString(), endAt: end.toISOString(), status: 'approved', createdAt: addMinutes(now, -35).toISOString(), reviewedBy: 'member-14', reviewedAt: addMinutes(now, -30).toISOString() });
  const pendingStart = addMinutes(now, 30);
  requests.push({ id: 'demo-request-2', memberId: 'member-13', type: 'kt', reason: 'Knowledge transfer', details: 'Pairing session', startAt: pendingStart.toISOString(), endAt: addMinutes(pendingStart, 45).toISOString(), status: 'pending', createdAt: addMinutes(now, -5).toISOString() });
  const allocations = [
    { id: 'demo-a1', memberId: 'member-09', assignedBy: 'member-14', assignedAt: addMinutes(now, -75).toISOString(), reference: 'DEMO-1001' },
    { id: 'demo-a2', memberId: 'member-10', assignedBy: 'member-14', assignedAt: addMinutes(now, -55).toISOString(), reference: 'DEMO-1002' },
    { id: 'demo-a3', memberId: 'member-12', assignedBy: 'member-14', assignedAt: addMinutes(now, -25).toISOString(), reference: 'DEMO-1003' },
  ];
  return {
    workspaceName: 'Operations team', timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'Asia/Kolkata',
    members, shifts: members.map((m) => ({ id: `shift-${m.id}`, memberId: m.id, date, key: m.shiftKey, start: m.shift.start, end: m.shift.end })),
    breaks: members.flatMap((m) => m.breaks), requests, allocations, handovers: [], currentAssigneeId: 'member-14',
    lastAllocatedMemberId: 'member-12', activities: [], attendance: [],
  };
}

function loadDemoState() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
    if (saved?.members?.length === 14) return { attendance: [], ...saved };
  } catch { /* corrupted demo storage is replaced with safe sample data */ }
  const fresh = demoSeed();
  localStorage.setItem(STORAGE_KEY, JSON.stringify(fresh));
  return fresh;
}

function saveDemoState() {
  if (!remoteMode && state) localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
}

function mapDashboard(payload) {
  const mapped = {
    workspaceName: payload.workspaceName || 'Team workspace', timezone: payload.timezone || 'Asia/Kolkata',
    members: payload.members || [], shifts: payload.shifts || [], breaks: payload.breaks || [],
    requests: payload.requests || [], allocations: (payload.allocations || []).map((item) => ({ ...item, emailSubject: item.emailSubject || null })), handovers: payload.handovers || [], shiftSwaps: payload.shiftSwaps || [],
    currentAssigneeId: payload.currentAssigneeId || null, lastAllocatedMemberId: payload.lastAllocatedMemberId || null,
    activities: payload.activities || [], attendance: payload.attendance || [],
  };
  mapped.members = mapped.members.map((member) => {
    const todayParts = partsInTimezone(new Date(), mapped.timezone);
    const today = `${todayParts.year}-${todayParts.month}-${todayParts.day}`;
    let shift = mapped.shifts.find((item) => item.memberId === member.id && item.date === today);
    if (!shift) {
      const previous = new Date(`${today}T00:00:00Z`); previous.setUTCDate(previous.getUTCDate() - 1);
      const previousDate = previous.toISOString().slice(0, 10);
      shift = mapped.shifts.find((item) => item.memberId === member.id && item.date === previousDate && item.start > item.end);
    }
    return { ...member, shift: shift || null, breaks: mapped.breaks.filter((item) => item.memberId === member.id), requests: mapped.requests.filter((item) => item.memberId === member.id) };
  });
  return mapped;
}

async function connectRemote() {
  const { createClient } = await import('https://esm.sh/@supabase/supabase-js@2');
  supabase = createClient(CONFIG.supabaseUrl, CONFIG.supabaseAnonKey, {
    auth: { autoRefreshToken: true, persistSession: true, detectSessionInUrl: false },
  });
  const { data: { session }, error: sessionError } = await supabase.auth.getSession();
  if (sessionError) throw sessionError;
  if (!session) {
    const { error } = await supabase.auth.signInAnonymously();
    if (error) throw error;
  }
  remoteMode = true;
  const { data: me, error } = await supabase.rpc('get_my_member');
  if (error) throw error;
  if (me?.member_id) {
    currentMemberId = me.member_id; workspaceId = me.workspace_id; setupRealtime();
    await reloadRemote();
    return;
  }
  showJoinScreen();
}

function setupRealtime() {
  if (!supabase || !workspaceId || realtimeChannel) return;
  realtimeChannel = supabase.channel(`whos-next-${workspaceId}`, { config: { broadcast: { self: false } } })
    .on('broadcast', { event: 'refresh' }, () => { reloadRemote().catch((error) => toast(error.message || 'Live refresh failed.', true)); })
    .subscribe();
}

async function reloadRemote() {
  if (refreshInProgress) return;
  refreshInProgress = true;
  try {
    const { error: handoverError } = await supabase.rpc('ensure_shift_assignee');
    if (handoverError) throw handoverError;
    const { data, error } = await supabase.rpc('get_dashboard');
    if (error) throw error;
    state = mapDashboard(data || {});
    renderApp();
  } finally { refreshInProgress = false; }
}

function showJoinScreen(message = '') {
  $('#app').innerHTML = `
    <main class="join-screen"><section class="join-card">
      <div class="brand"><span class="brand-mark">W</span><div><div class="brand-copy">WHO'S <span>next</span></div><div class="workspace-tag">Team operations</div></div></div>
      <div class="eyebrow">Your team workspace</div><h1>Step into your shift.</h1>
      <p>Enter the individual access code shared with you. Your code identifies your team profile—no username, email or password required.</p>
      ${message ? `<div class="notice">${escapeHtml(message)}</div>` : ''}
      <form id="join-form">
        <div class="field"><label for="join-code">Your individual access code</label><input id="join-code" name="code" type="password" autocomplete="one-time-code" required minlength="16" maxlength="200" placeholder="Enter your personal team code" /></div>
        <button class="button button-primary" type="submit">Open workspace <span>→</span></button>
      </form>
      <div class="join-help">Your code maps to one team member. Keep it private and contact the workspace owner if it is lost or exposed.</div>
    </section></main>`;
  $('#join-form').addEventListener('submit', joinWorkspace);
}

async function joinWorkspace(event) {
  event.preventDefault();
  const code = $('#join-code').value.trim();
  if (code.length < 16) return toast('Enter the individual access code shared with you.', true);
  const button = $('#join-form button[type="submit"]');
  button.disabled = true; button.textContent = 'Opening workspace…';
  try {
    const { data, error } = await supabase.rpc('join_workspace', { p_access_code: code });
    if (error) throw error;
    currentMemberId = data.member_id; workspaceId = data.workspace_id; setupRealtime();
    await reloadRemote();
  } catch (error) {
    toast(error.message || 'Unable to join workspace.', true);
    button.disabled = false; button.innerHTML = 'Open workspace <span>→</span>';
  }
}

function domainMembers() {
  const today = localDate();
  return state.members.map((member) => {
    let shift = state.shifts.find((item) => item.memberId === member.id && item.date === today) || member.shift;
    if (!shift) {
      const previous = new Date(`${today}T00:00:00Z`); previous.setUTCDate(previous.getUTCDate() - 1);
      const prev = previous.toISOString().slice(0, 10);
      shift = state.shifts.find((item) => item.memberId === member.id && item.date === prev && item.start > item.end) || null;
    }
    return { ...member, shift, breaks: state.breaks.filter((item) => item.memberId === member.id), requests: state.requests.filter((item) => item.memberId === member.id) };
  });
}

function currentMember() { return state?.members.find((member) => member.id === currentMemberId) || null; }
function currentAssignee() { return state?.members.find((member) => member.id === state.currentAssigneeId) || null; }
function contextNow() { return { now: new Date().toISOString(), date: localDate(), time: localTime() }; }
function eligibleMembers() { return getEligibleMembers(domainMembers(), contextNow()); }
function queueMembers(existingTicket = false) {
  if (!existingTicket) return buildRotation(domainMembers(), state.lastAllocatedMemberId, contextNow());
  const eligible = getTicketEligibleMembers(domainMembers(), contextNow());
  const lastIndex = eligible.findIndex((member) => member.id === state.lastAllocatedMemberId);
  return lastIndex < 0 ? eligible : [...eligible.slice(lastIndex + 1), ...eligible.slice(0,lastIndex + 1)];
}
function isCurrentAssignee() { return Boolean(currentMemberId && currentMemberId === state.currentAssigneeId); }
function logActivity(text, icon = '•') {
  state.activities.unshift({ id: id(), text, icon, createdAt: new Date().toISOString() });
  state.activities = state.activities.slice(0, 30);
}

function renderApp() {
  const me = currentMember();
  if (!me) return showJoinScreen('Your selected profile is no longer available. Rejoin with the team code.');
  const members = domainMembers();
  const statuses = members.map((member) => ({ member, status: getMemberStatus(member, contextNow()) }));
  const counts = {
    available: statuses.filter((x) => x.status.code === 'available').length,
    break: statuses.filter((x) => x.status.tone === 'warning').length,
    unavailable: statuses.filter((x) => x.status.tone === 'danger').length,
    pending: state.requests.filter((r) => r.status === 'pending').length,
    allocations: state.allocations.filter((a) => localDate(new Date(a.assignedAt)) === localDate()).length,
  };
  const assignee = currentAssignee();
  $('#app').innerHTML = `
    <div class="layout">
      <aside class="sidebar">
        <div><div class="brand"><span class="brand-mark">W</span><div class="brand-copy">WHO'S <span>next</span></div></div><div class="workspace-tag">${escapeHtml(state.workspaceName)}</div></div>
        <div><div class="nav-label">Workspace</div><nav class="nav" aria-label="Main navigation">
          ${navButton('allocation','⇄','Allocate')}${navButton('overview','⌂','Team overview')}${navButton('schedule','▦','My profile')}${navButton('requests','↗','Requests',counts.pending)}${navButton('reports','▤','Reports')}
        </nav></div>
        <div class="sidebar-bottom">
          ${remoteMode ? '<div class="demo-note" style="border-color:#355944;background:#183327;color:#a6d9b5">Live team workspace<br/>Changes sync across browsers.</div>' : '<div class="demo-note">Preview mode<br/>Sample team data is stored only in this browser. Connect Supabase for shared live data.</div>'}
          <div class="profile-mini"><span class="avatar">${initials(me.name)}</span><div style="min-width:0;flex:1"><strong>${escapeHtml(me.name)}</strong><small>Signed in as · ${isCurrentAssignee() ? 'Shift allocation owner' : 'Team member'}</small>${remoteMode ? '' : `<select id="demo-profile" aria-label="Preview as team member" style="margin-top:6px;max-width:155px;background:#111923;border:1px solid #334253;color:#9eafc2;border-radius:6px;padding:4px;font-size:9px">${state.members.map((m)=>`<option value="${m.id}" ${m.id===currentMemberId?'selected':''}>${escapeHtml(m.name)}</option>`).join('')}</select>`}</div></div>
        </div>
      </aside>
      <main class="main">
        <header class="topbar"><div><div class="eyebrow">${activeView === 'overview' ? 'Live operations' : 'Team workspace'}</div><h1 class="page-title">${viewTitle(activeView)}</h1></div><div class="top-actions"><span id="workspace-clock" class="digital-clock" aria-label="Workspace time">--:--:--</span>${remoteMode ? '<span class="live-pill"><i class="live-dot"></i> Live sync</span>' : '<span class="demo-pill">● Local preview</span>'}<button class="button button-secondary button-small" id="refresh-workspace">↻ Refresh</button><button class="button button-secondary button-small" id="new-request-top">＋ New request</button></div></header>
        <section class="section-view ${activeView === 'overview' ? 'active' : ''}" id="view-overview">${renderOverview(me, assignee, counts, statuses)}</section>
        <section class="section-view ${activeView === 'schedule' ? 'active' : ''}" id="view-schedule">${renderSchedule(me)}</section>
        <section class="section-view ${activeView === 'requests' ? 'active' : ''}" id="view-requests">${renderRequests(me)}</section>
        <section class="section-view ${activeView === 'allocation' ? 'active' : ''}" id="view-allocation">${renderAllocation(me, assignee)}</section>
        <section class="section-view ${activeView === 'reports' ? 'active' : ''}" id="view-reports">${renderReports()}</section>
      </main>
    </div>`;
  if (remoteMode) initializeNotificationCenter({ supabase, memberId: currentMemberId });
  $('.nav button').forEach((button) => button.addEventListener('click', () => { activeView = button.dataset.view; renderApp(); }));
  $('#new-request-top')?.addEventListener('click', openRequestDialog);
  $('#refresh-workspace')?.addEventListener('click', async () => { try { if (remoteMode) await reloadRemote(); else renderApp(); toast('Workspace refreshed.'); } catch (error) { toast(error.message || 'Refresh failed.', true); } });
  $('#demo-profile')?.addEventListener('change', (event) => { currentMemberId = event.target.value; localStorage.setItem(PROFILE_KEY, currentMemberId); renderApp(); });
  bindViewActions();
  startWorkspaceClock();
  scheduleOperationalRefresh();
  if (remoteMode && !state.shifts.some((shift) => shift.memberId === currentMemberId) && !sessionStorage.getItem(`whos-next-shift-setup-${currentMemberId}`)) {
    sessionStorage.setItem(`whos-next-shift-setup-${currentMemberId}`, 'shown');
    window.setTimeout(() => openShiftDialog(), 250);
  }
}

function startWorkspaceClock() {
  const update = () => {
    const clock = $('#workspace-clock');
    if (clock) clock.textContent = new Intl.DateTimeFormat(undefined, { timeZone: state?.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone, hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }).format(new Date());
    const countdown = $('#break-countdown');
    if (countdown) {
      const member = domainMembers().find((entry) => entry.id === currentMemberId);
      const status = member ? getMemberStatus(member, contextNow()) : null;
      if (status?.code === 'break' && status.returnAt) {
        const end = new Date(workspaceInputToIso(status.returnAt.slice(0,16))).getTime();
        const seconds = Math.max(0, Math.floor((end - Date.now()) / 1000));
        countdown.textContent = `${String(Math.floor(seconds / 3600)).padStart(2,'0')}:${String(Math.floor((seconds % 3600) / 60)).padStart(2,'0')}:${String(seconds % 60).padStart(2,'0')}`;
      } else countdown.textContent = '00:00:00';
    }
  };
  update();
  if (clockTimer) clearInterval(clockTimer);
  clockTimer = setInterval(update, 1000);
}

function addCalendarDays(date, days) {
  const value = new Date(`${date}T00:00:00Z`);
  value.setUTCDate(value.getUTCDate() + days);
  return value.toISOString().slice(0, 10);
}

function nextOperationalBoundary() {
  const now = Date.now();
  const candidates = [];
  const addLocalBoundary = (date, time) => {
    try {
      const value = new Date(workspaceInputToIso(`${date}T${time}`)).getTime();
      if (Number.isFinite(value) && value > now) candidates.push(value);
    } catch { /* Ignore invalid or incomplete schedule entries. */ }
  };
  for (const shift of state.shifts || []) {
    const endDate = shift.end <= shift.start ? addCalendarDays(shift.date, 1) : shift.date;
    addLocalBoundary(shift.date, shift.start);
    addLocalBoundary(endDate, shift.end);
  }
  for (const item of state.breaks || []) {
    const endDate = item.end <= item.start ? addCalendarDays(item.date, 1) : item.date;
    addLocalBoundary(item.date, item.start);
    addLocalBoundary(endDate, item.end);
    const reminderAt = new Date(workspaceInputToIso(`${item.date}T${item.start}`)).getTime() - 5 * 60000;
    if (Number.isFinite(reminderAt) && reminderAt > now) candidates.push(reminderAt);
  }
  for (const request of state.requests || []) {
    if (request.status !== 'approved') continue;
    for (const value of [request.startAt, request.endAt]) {
      const timestamp = new Date(value).getTime();
      if (Number.isFinite(timestamp) && timestamp > now) candidates.push(timestamp);
    }
  }
  return candidates.length ? Math.min(...candidates) : null;
}

function scheduleOperationalRefresh() {
  if (boundaryTimer) clearTimeout(boundaryTimer);
  const boundary = nextOperationalBoundary();
  if (!boundary) return;
  const delay = Math.max(1000, boundary - Date.now() + 500);
  boundaryTimer = setTimeout(async () => {
    const reminder = (state.breaks || []).find((item) => {
      const startAt = new Date(workspaceInputToIso(`${item.date}T${item.start}`)).getTime();
      return startAt > Date.now() && startAt - Date.now() <= 5 * 60000 + 3000 && startAt - Date.now() >= 4 * 60000;
    });
    if (reminder) toast(`${reminder.breakType === 'meal' ? 'Meal break' : 'BioBreak'} starts in 5 minutes.`);
    if (refreshInProgress) return scheduleOperationalRefresh();
    try {
      if (remoteMode) await reloadRemote();
      else renderApp();
    } catch (error) { toast(error.message || 'Automatic shift refresh failed.', true); }
  }, delay);
}

function navButton(view, icon, label, badge = 0) {
  return `<button type="button" data-view="${view}" class="${activeView === view ? 'active' : ''}"><span class="nav-icon">${icon}</span>${label}${badge ? `<span style="margin-left:auto;background:#d1f36a;color:#1a220e;border-radius:99px;padding:2px 6px;font-size:9px">${badge}</span>` : ''}</button>`;
}
function viewTitle(view) {
  return ({ overview: 'Know who’s <em>next.</em>', schedule: 'Your <em>schedule.</em>', requests: 'Requests & <em>approvals.</em>', allocation: 'Fair work, <em>in order.</em>', reports: 'The shift, <em>at a glance.</em>' })[view] || 'WHO’S next';
}
function statCard(label, value, sub, icon) {
  return `<article class="stat-card"><div class="stat-head"><span>${label}</span><span class="stat-icon">${icon}</span></div><div class="stat-value">${value}</div><div class="stat-sub">${sub}</div></article>`;
}
function statusPill(status) { return `<span class="status ${status.tone}">${escapeHtml(status.label)}</span>`; }
function returnLabel(status) { return status.returnAt ? `Until ${prettyTime(status.returnAt)}` : status.code === 'available' ? 'Ready for allocation' : '—'; }

function latestAttendanceForCurrentMember() {
  return (state.attendance || []).filter((event) => event.memberId === currentMemberId).sort((a, b) => new Date(b.occurredAt) - new Date(a.occurredAt))[0] || null;
}

async function recordAttendance() {
  const latest = latestAttendanceForCurrentMember();
  const eventType = latest?.eventType === 'check_in' ? 'check_out' : 'check_in';
  try {
    if (remoteMode) await rpc('record_attendance', { p_event_type: eventType });
    else {
      const event = { id: id(), memberId: currentMemberId, eventType, occurredAt: new Date().toISOString() };
      state.attendance = [event, ...(state.attendance || [])];
      logActivity(`${currentMember().name} recorded shift ${eventType.replace('_', ' ')}.`, '◷');
      saveDemoState();
    }
    await refreshAfterAction(eventType === 'check_in' ? 'Shift check-in recorded.' : 'Shift check-out recorded.');
  } catch (error) { toast(error.message || 'Attendance could not be recorded.', true); }
}

function renderOverview(me, assignee, counts, statuses) {
  const queue = queueMembers();
  const pending = state.requests.filter((request) => request.status === 'pending').slice(0, 3);
  const allocations = state.allocations.slice(0, 5);
  const myStatus = statuses.find(({ member }) => member.id === currentMemberId)?.status;
  const hour = Number(localTime().slice(0, 2));
  return `
    <div class="greeting-row"><div><div class="eyebrow">${prettyDate(localDate())} · ${localTime()} local time</div><h2 style="font:800 19px Manrope;margin:8px 0 0">Good ${hour < 12 ? 'morning' : hour < 17 ? 'afternoon' : 'evening'}, ${escapeHtml(me.name.split(' ')[0])}.</h2><p>Here’s the current pulse of your team. Keep the next handover clear.</p></div><div class="date-stamp"><strong>${escapeHtml(state.workspaceName)}</strong>${statuses.length} rostered team members</div></div>
    <div class="stats">${statCard('AVAILABLE NOW', counts.available, 'Eligible for the next allocation', '✓')}${statCard('ON BREAK / BUSY', counts.break, 'Scheduled or approved unavailability', '◷')}${statCard('NEEDS REVIEW', counts.pending, 'Pending team requests', '↗')}${statCard('ALLOCATED TODAY', counts.allocations, 'Assignments recorded in WHO’S next', '⇄')}</div>
    <div class="middle-grid">
      <section class="panel"><div class="panel-head"><div><div class="panel-title">Allocation control</div><div class="panel-subtitle">The current handover owner and next eligible employees</div></div><button class="text-link" data-go="allocation">Open queue →</button></div>
        <div class="assignee-card"><span class="avatar">${assignee ? initials(assignee.name) : '?'}</span><div class="assignee-meta"><strong>${assignee ? escapeHtml(assignee.name) : 'No assignee selected'}</strong><small>${assignee ? 'Currently responsible for email allocation' : 'Take over to become the allocation owner'}</small></div><div class="assignee-actions">${isCurrentAssignee() ? '<span class="queue-tag">YOU OWN THE QUEUE</span>' : '<button class="button button-secondary button-small" id="take-over">Take over</button>'}</div></div>
        <div class="panel-head" style="margin:0 0 9px"><div class="panel-title" style="font-size:12px">Who’s next in line</div><span class="panel-subtitle">${queue.length} eligible</span></div>
        <div class="queue-list">${queue.length ? queue.slice(0, 4).map((member, index) => `<div class="queue-item"><span class="queue-number">${String(index + 1).padStart(2, '0')}</span><span class="avatar">${initials(member.name)}</span><div class="queue-person"><strong>${escapeHtml(member.name)}</strong><small>${escapeHtml(SHIFT_PRESETS[member.shiftKey || member.shift?.key]?.label || 'Scheduled shift')}</small></div><span class="queue-tag">READY</span></div>`).join('') : '<div class="empty-state">No one is currently eligible. The queue will refresh as schedules and approvals change.</div>'}</div>
        <div class="queue-footer"><span>Pointer advances only when an allocation is recorded.</span><button class="button button-primary button-small" id="record-next" ${queue.length && isCurrentAssignee() ? '' : 'disabled'}>Record next allocation →</button></div>
      </section>
      <section class="panel"><div class="panel-head"><div><div class="panel-title">Team pulse</div><div class="panel-subtitle">Live view of the current shift</div></div><button class="text-link" data-go="schedule">My schedule →</button></div>
        <div class="report-grid" style="grid-template-columns:1fr 1fr;margin:0 0 13px"> <div class="report-card"><small>Working now</small><strong>${statuses.filter((x) => x.status.code !== 'off_shift' && x.status.code !== 'leave').length}</strong></div><div class="report-card"><small>Off shift / leave</small><strong>${statuses.filter((x) => ['off_shift','leave'].includes(x.status.code)).length}</strong></div></div>
        <div class="muted-copy">WHO’S next uses scheduled shifts, breaks and approved unavailability to calculate allocation eligibility. Requests still awaiting a decision do not remove an employee from the queue.</div>
        <div class="attendance-control"><div><strong>Shift attendance</strong><small>${latestAttendanceForCurrentMember()?.eventType === 'check_in' ? `Checked in at ${prettyTime(latestAttendanceForCurrentMember().occurredAt)}` : latestAttendanceForCurrentMember()?.eventType === 'check_out' ? `Last checked out at ${prettyTime(latestAttendanceForCurrentMember().occurredAt)}` : 'No attendance event recorded yet'}</small></div><button class="button button-secondary button-small" id="attendance-toggle">${latestAttendanceForCurrentMember()?.eventType === 'check_in' ? 'Check out' : 'Check in'}</button></div>
        <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:12px">${myStatus?.code === 'break' ? '<button class="button button-secondary button-small" id="extend-break">＋ Extend my break</button>' : '<button class="button button-secondary button-small" id="add-break">＋ Plan a break</button>'}<button class="button button-secondary button-small" id="set-shift">▦ Update shift</button></div>
      </section>
    </div>
    <section class="panel team-panel" style="margin-bottom:16px"><div class="panel-head"><div><div class="panel-title">Team availability</div><div class="panel-subtitle">Eligibility is recalculated from the current shift and approved time windows</div></div><span class="panel-subtitle">${counts.available} available / ${statuses.length} total</span></div>
      <div class="table-wrap"><table class="team-table"><thead><tr><th>Team member</th><th>Shift</th><th>Status</th><th>Reason</th><th>Expected return</th></tr></thead><tbody>${statuses.map(({ member, status }) => `<tr><td><div class="employee-cell"><span class="avatar">${initials(member.name)}</span><div><strong>${escapeHtml(member.name)}</strong><small>${member.id === currentMemberId ? 'You' : 'Team member'}</small></div></div></td><td>${member.shift ? `${member.shift.start} – ${member.shift.end}` : '—'}</td><td>${statusPill(status)}</td><td>${escapeHtml(status.reason)}</td><td class="return-time">${returnLabel(status)}</td></tr>`).join('')}</tbody></table></div>
    </section>
    <div class="bottom-grid"><section class="panel"><div class="panel-head"><div><div class="panel-title">Requests to review</div><div class="panel-subtitle">Pending requests transfer with the assignee handover</div></div><button class="text-link" data-go="requests">View all →</button></div><div class="request-list">${pending.length ? pending.map(renderRequestCard).join('') : '<div class="empty-state">No pending requests. Your approval queue is clear.</div>'}</div></section>
      <section class="panel"><div class="panel-head"><div><div class="panel-title">Recent allocation activity</div><div class="panel-subtitle">Latest assignments recorded</div></div><button class="text-link" data-go="reports">View reports →</button></div><div class="activity-list">${allocations.length ? allocations.map((item) => { const recipient = state.members.find((m) => m.id === item.memberId); const assigner = state.members.find((m) => m.id === item.assignedBy); return `<div class="activity-item"><span class="activity-icon">⇄</span><div class="activity-copy"><p><strong>${escapeHtml(recipient?.name || 'Unknown member')}</strong> received an allocation from ${escapeHtml(assigner?.name || 'Unknown assignee')} ${item.reference ? `· ${escapeHtml(item.reference)}` : ''}</p><small>${prettyDateTime(item.assignedAt)}</small></div></div>`; }).join('') : '<div class="empty-state">No allocations have been recorded yet.</div>'}</div></section></div>`;
}

function renderRequestCard(request) {
  const owner = state.members.find((member) => member.id === request.memberId);
  const canReview = isCurrentAssignee() && request.status === 'pending' && request.memberId !== currentMemberId;
  return `<article class="request-card"><span class="avatar">${initials(owner?.name || '?')}</span><div class="request-content"><strong>${escapeHtml(owner?.name || 'Unknown member')} · ${escapeHtml(REQUEST_TYPES[request.type] || request.type)}</strong><p>${escapeHtml(request.reason || 'No reason provided')} · ${prettyDateTime(request.startAt)} – ${prettyTime(request.endAt)}</p><span class="request-time">Submitted ${prettyDateTime(request.createdAt)} · ${escapeHtml(request.status)}</span>${canReview ? `<div class="request-actions"><button class="button button-primary" data-review="${request.id}" data-decision="approved">Approve</button><button class="button button-danger" data-review="${request.id}" data-decision="rejected">Reject</button></div>` : ''}</div></article>`;
}

function renderSchedule(me) {
  const shifts = state.shifts.filter((shift) => shift.memberId === currentMemberId).sort((a, b) => a.date.localeCompare(b.date));
  const breaks = state.breaks.filter((item) => item.memberId === currentMemberId).sort((a, b) => `${a.date}${a.start}`.localeCompare(`${b.date}${b.start}`));
  return `<div class="page-toolbar"><div><div class="panel-title">Your shifts & breaks</div><div class="panel-subtitle">Manage only your own schedule. Changes are retained in history.</div></div><div class="toolbar-actions"><button class="button button-secondary" id="add-break">＋ Add break</button><button class="button button-secondary" id="new-shift-swap">⇄ Request swap</button><button class="button button-primary" id="set-shift">＋ Set shift</button></div></div>
    <section class="panel" style="margin-bottom:15px"><div class="panel-head"><div><div class="panel-title">Scheduled shifts</div><div class="panel-subtitle">${shifts.length} shift record(s)</div></div></div><div class="schedule-list">${shifts.length ? shifts.map((shift) => `<div class="schedule-row"><div><strong>${prettyDate(shift.date)}</strong><small style="display:block">${escapeHtml(SHIFT_PRESETS[shift.key]?.label || shift.key || 'Custom shift')}</small></div><div>${shift.start}</div><div>${shift.end}</div><div><button class="button button-secondary button-small" data-edit-shift="${shift.id}">Edit</button></div></div>`).join('') : '<div class="empty-state">No shifts have been entered. Add your first shift to appear in the team schedule.</div>'}</div></section>
    <section class="panel" style="margin-bottom:15px"><div class="panel-head"><div><div class="panel-title">Planned breaks</div><div class="panel-subtitle">Breaks are used to calculate eligibility during the selected time window</div></div></div><div class="schedule-list">${breaks.length ? breaks.map((item) => `<div class="schedule-row"><div><strong>${prettyDate(item.date)}</strong><small style="display:block">${item.breakType === 'meal' ? 'Meal break' : 'BioBreak'} · ${escapeHtml(item.note || 'Scheduled break')}</small></div><div>${item.start}</div><div>${item.end}</div><div><span class="status muted">Scheduled</span></div></div>`).join('') : '<div class="empty-state">No breaks planned yet.</div>'}</div></section>
    <section class="panel"><div class="panel-head"><div><div class="panel-title">One-day shift swaps</div><div class="panel-subtitle">A swap takes effect only after the invited colleague accepts</div></div></div><div class="request-list">${(state.shiftSwaps || []).filter((swap) => swap.requesterMemberId === currentMemberId || swap.partnerMemberId === currentMemberId).length ? (state.shiftSwaps || []).filter((swap) => swap.requesterMemberId === currentMemberId || swap.partnerMemberId === currentMemberId).map(renderShiftSwapCard).join('') : '<div class="empty-state">No shift swap requests involving you.</div>'}</div></section>`;
}

function renderShiftSwapCard(swap) {
  const requester = state.members.find((member) => member.id === swap.requesterMemberId);
  const partner = state.members.find((member) => member.id === swap.partnerMemberId);
  const incoming = swap.partnerMemberId === currentMemberId;
  const canRespond = incoming && swap.status === 'pending';
  return `<article class="request-card"><span class="avatar">⇄</span><div class="request-content"><strong>${escapeHtml(requester?.name || 'Unknown')} ↔ ${escapeHtml(partner?.name || 'Unknown')}</strong><p>One-day shift exchange · ${prettyDate(swap.workDate)}</p><span class="request-time">${escapeHtml(swap.status)} · requested ${prettyDateTime(swap.createdAt)}</span>${canRespond ? `<div class="request-actions"><button class="button button-primary" data-swap-response="${swap.id}" data-accept="true">Accept swap</button><button class="button button-danger" data-swap-response="${swap.id}" data-accept="false">Reject</button></div>` : ''}</div></article>`;
}

function renderRequests(me) {
  const sorted = [...state.requests].sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
  const pending = sorted.filter((r) => r.status === 'pending');
  const mine = sorted.filter((r) => r.memberId === currentMemberId);
  const canReview = isCurrentAssignee();
  return `<div class="page-toolbar"><div><div class="panel-title">Request centre</div><div class="panel-subtitle">Submit a request or review the team's pending items</div></div><button class="button button-primary" id="new-request-page">＋ New request</button></div>
    ${canReview ? `<section class="panel" style="margin-bottom:15px"><div class="panel-head"><div><div class="panel-title">Approval inbox</div><div class="panel-subtitle">You are the current email assignee and can approve or reject requests</div></div><span class="queue-tag">${pending.length} PENDING</span></div><div class="request-list">${pending.length ? pending.map(renderRequestCard).join('') : '<div class="empty-state">Nothing is waiting for your decision.</div>'}</div></section>` : '<div class="notice">Only the current email assignee can approve or reject requests. Pending requests remain visible to the next assignee after a handover.</div>'}
    <section class="panel" style="margin-bottom:15px"><div class="panel-head"><div><div class="panel-title">My requests</div><div class="panel-subtitle">Your submissions and decisions</div></div></div><div class="request-list">${mine.length ? mine.map(renderRequestCard).join('') : '<div class="empty-state">You have not submitted any requests.</div>'}</div></section>
    <section class="panel" style="margin-bottom:15px"><div class="panel-head"><div><div class="panel-title">Shift swap inbox</div><div class="panel-subtitle">Only the invited colleague can accept or reject a swap</div></div></div><div class="request-list">${(state.shiftSwaps || []).filter((swap) => swap.partnerMemberId === currentMemberId || swap.requesterMemberId === currentMemberId).length ? (state.shiftSwaps || []).filter((swap) => swap.partnerMemberId === currentMemberId || swap.requesterMemberId === currentMemberId).map(renderShiftSwapCard).join('') : '<div class="empty-state">No shift swap requests involving you.</div>'}</div></section>
    <section class="panel"><div class="panel-head"><div><div class="panel-title">Team request history</div><div class="panel-subtitle">All request statuses, newest first</div></div></div><div class="request-list">${sorted.length ? sorted.map((request) => `<article class="request-card"><span class="avatar">${initials(state.members.find((m) => m.id === request.memberId)?.name || '?')}</span><div class="request-content"><strong>${escapeHtml(state.members.find((m) => m.id === request.memberId)?.name || 'Unknown')} · ${escapeHtml(REQUEST_TYPES[request.type] || request.type)}</strong><p>${escapeHtml(request.reason || '')} · ${prettyDateTime(request.startAt)} – ${prettyDateTime(request.endAt)}</p><span class="request-time">${escapeHtml(request.status)} · submitted ${prettyDateTime(request.createdAt)}${request.reviewedAt ? ` · reviewed ${prettyDateTime(request.reviewedAt)}` : ''}</span></div></article>`).join('') : '<div class="empty-state">No request history yet.</div>'}</div></section>`;
}

function renderAllocation(me, assignee) {
  const queue = queueMembers();
  const today = state.allocations.filter((item) => localDate(new Date(item.assignedAt)) === localDate());
  const myStatus = getMemberStatus(domainMembers().find((member) => member.id === currentMemberId), contextNow());
  return `<div class="page-toolbar"><div><div class="panel-title">Round-robin queue</div><div class="panel-subtitle">Unavailable colleagues automatically return to the queue when their break or approved time window ends.</div></div><div class="toolbar-actions"><button class="button button-secondary" id="take-over" ${isCurrentAssignee() ? 'disabled' : ''}>Take over responsibility</button><button class="button button-secondary" id="record-ticket" ${isCurrentAssignee() ? '' : 'disabled'}>Route existing ticket</button><button class="button button-primary" id="record-next" ${queue.length && isCurrentAssignee() ? '' : 'disabled'}>Record new email →</button></div></div>${myStatus.code === 'break' ? `<div class="notice break-active-notice">You are on ${escapeHtml(myStatus.reason)} · returns at ${prettyTime(myStatus.returnAt)} · <strong id="break-countdown">--:--:--</strong> remaining. New email allocation is paused.</div>` : ''}
    <div class="notice">Assign the email in Outlook first, then record it here. WHO'S next captures the recipient, assigner, optional subject/reference and exact server timestamp. The next colleague becomes first in line immediately after the record succeeds.</div>
    <section class="panel" style="margin-bottom:15px"><div class="panel-head"><div><div class="panel-title">Current responsibility</div><div class="panel-subtitle">Automatically follows the active shift when the current owner goes off shift or becomes unavailable</div></div></div><div class="assignee-card"><span class="avatar">${assignee ? initials(assignee.name) : '?'}</span><div class="assignee-meta"><strong>${escapeHtml(assignee?.name || 'Not assigned')}</strong><small>${isCurrentAssignee() ? 'You are currently responsible for allocation' : 'Current allocation owner'}</small></div></div><div class="muted-copy">Your profile remains signed in. Only the shared allocation responsibility changes at shift handover.</div></section>
    <section class="panel" style="margin-bottom:15px"><div class="panel-head"><div><div class="panel-title">Next eligible sequence</div><div class="panel-subtitle">${queue.length} people ready · last allocation to ${escapeHtml(state.members.find((m) => m.id === state.lastAllocatedMemberId)?.name || 'nobody yet')}</div></div></div><div class="queue-list">${queue.length ? queue.map((member, index) => `<div class="queue-item"><span class="queue-number">${String(index + 1).padStart(2, '0')}</span><span class="avatar">${initials(member.name)}</span><div class="queue-person"><strong>${escapeHtml(member.name)}</strong><small>${escapeHtml(SHIFT_PRESETS[member.shiftKey || member.shift?.key]?.label || 'Scheduled shift')}</small></div><span class="queue-tag">ELIGIBLE</span></div>`).join('') : '<div class="empty-state">No eligible employees at the moment.</div>'}</div></section>
    <section class="panel"><div class="panel-head"><div><div class="panel-title">Today’s allocation log</div><div class="panel-subtitle">${today.length} assignment(s) recorded today · newest first</div></div></div><div class="schedule-list">${today.length ? today.map((item) => `<div class="schedule-row allocation-row"><div><strong>${escapeHtml(state.members.find((m) => m.id === item.memberId)?.name || 'Unknown member')}</strong><small style="display:block">Assigned by ${escapeHtml(state.members.find((m) => m.id === item.assignedBy)?.name || 'Unknown')}</small>${item.emailSubject ? `<small class="allocation-subject">${escapeHtml(item.emailSubject)}</small>` : ''}</div><div>${prettyDateTime(item.assignedAt)}</div><div>${escapeHtml(item.reference || 'No reference')}</div><div><span class="status success">Recorded</span></div></div>`).join('') : '<div class="empty-state">No assignments recorded today.</div>'}</div></section>`;
}

function renderAllocationTimelineItem(item) {
  const recipient = state.members.find((member) => member.id === item.memberId)?.name || 'Unknown recipient';
  const assigner = state.members.find((member) => member.id === item.assignedBy)?.name || 'Unknown assigner';
  return `<div class="schedule-row allocation-row"><div><strong>${escapeHtml(recipient)}</strong><small style="display:block">Assigned by ${escapeHtml(assigner)}</small>${item.emailSubject ? `<small class="allocation-subject">${escapeHtml(item.emailSubject)}</small>` : ''}</div><div>${prettyDateTime(item.assignedAt)}</div><div>${escapeHtml(item.reference || 'No reference')}</div><div><span class="status success">Assigned</span></div></div>`;
}

function renderReports() {
  const allocations = state.allocations;
  const allMembers = state.members;
  const totals = allMembers.map((member) => ({ ...member, count: allocations.filter((a) => a.memberId === member.id).length }));
  const sorted = [...totals].sort((a, b) => b.count - a.count);
  const total = allocations.length;
  const pending = state.requests.filter((r) => r.status === 'pending').length;
  const approved = state.requests.filter((r) => r.status === 'approved').length;
  const rejected = state.requests.filter((r) => r.status === 'rejected').length;
  const attendance = (state.attendance || []).slice(0, 20);
  const timeline = [...allocations].sort((a, b) => new Date(b.assignedAt) - new Date(a.assignedAt)).slice(0, 100);
  return `<div class="page-toolbar"><div><div class="panel-title">Operational reports</div><div class="panel-subtitle">Historical totals from records entered in WHO’S next</div></div><button class="button button-secondary" id="export-csv">↓ Export allocations CSV</button></div>
    <div class="report-grid"><div class="report-card"><small>Total assignments recorded</small><strong>${total}</strong></div><div class="report-card"><small>Requests approved</small><strong>${approved}</strong></div><div class="report-card"><small>Requests pending / rejected</small><strong>${pending} / ${rejected}</strong></div></div>
    <section class="panel" style="margin-bottom:15px"><div class="panel-head"><div><div class="panel-title">Allocation distribution</div><div class="panel-subtitle">All recorded allocations, grouped by recipient</div></div></div><div class="schedule-list">${sorted.map((member) => `<div class="schedule-row"><div><strong>${escapeHtml(member.name)}</strong><small style="display:block">${member.id === currentMemberId ? 'You' : 'Team member'}</small></div><div>${member.count} allocation(s)</div><div><div style="height:7px;background:#283746;border-radius:99px;overflow:hidden"><div style="height:100%;width:${total ? member.count / Math.max(1, sorted[0].count) * 100 : 0}%;background:var(--accent);border-radius:99px"></div></div></div><div><span class="status muted">History</span></div></div>`).join('')}</div></section>
    <section class="panel" style="margin-bottom:15px"><div class="panel-head"><div><div class="panel-title">Email assignment timeline</div><div class="panel-subtitle">Recipient, assigner, subject and exact recorded timestamp · latest 100</div></div></div><div class="schedule-list">${timeline.length ? timeline.map(renderAllocationTimelineItem).join('') : '<div class="empty-state">No email assignments have been recorded yet.</div>'}</div></section>\n    <section class="panel" style="margin-bottom:15px"><div class="panel-head"><div><div class="panel-title">Recent attendance events</div><div class="panel-subtitle">Self-recorded shift check-in and check-out events · latest 20</div></div></div><div class="schedule-list">${attendance.length ? attendance.map((event) => `<div class="schedule-row"><div><strong>${escapeHtml(state.members.find((m) => m.id === event.memberId)?.name || 'Unknown member')}</strong></div><div>${event.eventType === 'check_in' ? 'Check-in' : 'Check-out'}</div><div>${prettyDateTime(event.occurredAt)}</div><div><span class="status muted">Recorded</span></div></div>`).join('') : '<div class="empty-state">No attendance events have been recorded yet.</div>'}</div></section>
    <section class="panel"><div class="panel-head"><div><div class="panel-title">Audit and handover history</div><div class="panel-subtitle">Recent operational events</div></div></div><div class="activity-list">${[...state.handovers.map((h) => ({ ...h, text: `${state.members.find((m) => m.id === h.fromMemberId)?.name || 'Unassigned'} handed allocation to ${state.members.find((m) => m.id === h.toMemberId)?.name || 'Unknown'}`, icon: '⇄' })), ...state.activities].sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt)).slice(0, 20).map((item) => `<div class="activity-item"><span class="activity-icon">${escapeHtml(item.icon || '•')}</span><div class="activity-copy"><p>${escapeHtml(item.text)}</p><small>${prettyDateTime(item.createdAt)}</small></div></div>`).join('') || '<div class="empty-state">Audit events will appear here as the team uses the workspace.</div>'}</div></section>`;
}

function bindViewActions() {
  $$('[data-go]').forEach((button) => button.addEventListener('click', () => { activeView = button.dataset.go; renderApp(); }));
  $('#take-over')?.addEventListener('click', takeOver);
  $('#attendance-toggle')?.addEventListener('click', recordAttendance);
  $('#record-next')?.addEventListener('click', () => openAllocationDialog(false));
  $('#record-ticket')?.addEventListener('click', () => openAllocationDialog(true));
  $('#add-break')?.addEventListener('click', () => openBreakDialog(false));
  $('#extend-break')?.addEventListener('click', () => openBreakDialog(true));
  $('#set-shift')?.addEventListener('click', () => openShiftDialog());
  $('#new-shift-swap')?.addEventListener('click', openShiftSwapDialog);
  $$('[data-swap-response]').forEach((button) => button.addEventListener('click', () => respondShiftSwap(button.dataset.swapResponse, button.dataset.accept === 'true')));
  $('#new-request-page')?.addEventListener('click', openRequestDialog);
  $$('[data-review]').forEach((button) => button.addEventListener('click', () => reviewRequest(button.dataset.review, button.dataset.decision)));
  $$('[data-edit-shift]').forEach((button) => button.addEventListener('click', () => openShiftDialog(button.dataset.editShift)));
  $('#export-csv')?.addEventListener('click', exportAllocations);
}

function openDialog(title, description, fields, submitLabel, onSubmit) {
  const dialog = $('#action-dialog');
  $('#dialog-content').innerHTML = `<div class="dialog-body"><div class="eyebrow">WHO’S next · Team action</div><h2>${escapeHtml(title)}</h2><p>${escapeHtml(description)}</p><form id="action-form">${fields}<div class="dialog-footer"><button type="button" class="button button-secondary" id="cancel-dialog">Cancel</button><button class="button button-primary" type="submit">${escapeHtml(submitLabel)}</button></div></form></div>`;
  $('#cancel-dialog').addEventListener('click', () => dialog.close());
  $('#action-form').addEventListener('submit', async (event) => { event.preventDefault(); const button = $('#action-form button[type="submit"]'); button.disabled = true; try { await onSubmit(new FormData(event.currentTarget)); dialog.close(); } catch (error) { toast(error.message || 'Action could not be completed.', true); button.disabled = false; } });
  dialog.showModal();
}

function openRequestDialog() {
  const now = new Date(); const later = addMinutes(now, 45);
  const options = Object.entries(REQUEST_TYPES).map(([value, label]) => `<option value="${value}">${escapeHtml(label)}</option>`).join('');
  openDialog('Raise an availability request', 'Pending requests do not remove you from the allocation queue. Only an approved request changes eligibility.', `
    <div class="form-grid"><div class="field"><label for="request-type">Request type</label><select id="request-type" name="type" required>${options}</select></div><div class="field"><label for="request-reason">Short reason</label><input id="request-reason" name="reason" maxlength="100" required placeholder="e.g. Daily operations sync" /></div><div class="field"><label for="request-start">Start</label><input id="request-start" name="startAt" type="datetime-local" required value="${localDateTime(now)}" /></div><div class="field"><label for="request-end">Expected end</label><input id="request-end" name="endAt" type="datetime-local" required value="${localDateTime(later)}" /></div><div class="field full"><label for="request-details">Additional details (optional)</label><textarea id="request-details" name="details" maxlength="500" placeholder="Add context for the current assignee"></textarea></div></div>`, 'Submit request', async (form) => {
    const request = { id: id(), memberId: currentMemberId, type: form.get('type'), reason: form.get('reason').trim(), details: form.get('details').trim(), startAt: workspaceInputToIso(form.get('startAt')), endAt: workspaceInputToIso(form.get('endAt')) };
    const error = validateRequestPeriod(request.startAt, request.endAt); if (error) throw new Error(error);
    if (remoteMode) await rpc('submit_availability_request', { p_type: request.type, p_reason: request.reason, p_details: request.details, p_start_at: request.startAt, p_end_at: request.endAt });
    else { Object.assign(request, { status: 'pending', createdAt: new Date().toISOString() }); state.requests.unshift(request); logActivity(`${currentMember().name} submitted a ${REQUEST_TYPES[request.type]} request.`, '↗'); saveDemoState(); }
    await refreshAfterAction('Request submitted. It will remain pending until reviewed.');
  });
}

function openShiftDialog(existingId = null) {
  const existing = existingId ? state.shifts.find((item) => item.id === existingId) : null;
  const date = existing?.date || localDate();
  const key = existing?.key || 'morning';
  const preset = SHIFT_PRESETS[key] || { start: existing?.start || '09:00', end: existing?.end || '18:00' };
  const presetOptions = Object.entries(SHIFT_PRESETS).map(([value, item]) => `<option value="${value}" ${key === value ? 'selected' : ''}>${escapeHtml(item.label)}</option>`).join('');
  openDialog(existing ? 'Update your shift' : 'Add a shift', 'Only your own schedule can be changed from this profile. Overnight shifts are supported.', `<div class="form-grid"><div class="field"><label for="shift-date">Work date</label><input id="shift-date" name="date" type="date" required value="${date}" /></div><div class="field"><label for="shift-preset">Shift pattern</label><select id="shift-preset" name="key">${presetOptions}<option value="custom" ${key === 'custom' ? 'selected' : ''}>Custom</option></select></div><div class="field"><label for="shift-start">Start time</label><input id="shift-start" name="start" type="time" required value="${existing?.start || preset.start}" /></div><div class="field"><label for="shift-end">End time</label><input id="shift-end" name="end" type="time" required value="${existing?.end || preset.end}" /></div></div>`, 'Save shift', async (form) => {
    const shift = { id: existing?.id || id(), memberId: currentMemberId, date: form.get('date'), key: form.get('key'), start: form.get('start'), end: form.get('end') };
    const error = validateTimeRange(shift.start, shift.end); if (error) throw new Error(error);
    if (remoteMode) await rpc('upsert_shift', { p_work_date: shift.date, p_shift_key: shift.key, p_start: shift.start, p_end: shift.end });
    else { const index = state.shifts.findIndex((item) => item.memberId === currentMemberId && item.date === shift.date); if (index >= 0) state.shifts[index] = shift; else state.shifts.push(shift); logActivity(`${currentMember().name} updated a shift for ${prettyDate(shift.date)}.`, '▦'); saveDemoState(); }
    await refreshAfterAction('Shift saved.');
  });
  $('#shift-preset')?.addEventListener('change', (event) => { const preset = SHIFT_PRESETS[event.target.value]; if (preset) { $('#shift-start').value = preset.start; $('#shift-end').value = preset.end; } });
}

function currentBreakForMember() {
  const date = localDate();
  const time = localTime();
  const previousDate = new Date(`${date}T00:00:00Z`);
  previousDate.setUTCDate(previousDate.getUTCDate() - 1);
  const previous = previousDate.toISOString().slice(0, 10);
  return state.breaks.find((item) => item.memberId === currentMemberId && (
    (item.date === date && (item.start < item.end ? time >= item.start && time < item.end : time >= item.start)) ||
    (item.date === previous && item.start > item.end && time < item.end)
  )) || null;
}

function openBreakDialog(extension = false) {
  const now = new Date();
  const activeBreak = extension ? currentBreakForMember() : null;
  let breakDate = localDate(now);
  let breakStart = localTime(now);
  let defaultEnd = localTime(addMinutes(now, 30));
  if (activeBreak) {
    breakDate = activeBreak.date;
    if (activeBreak.start > activeBreak.end) {
      const nextDate = new Date(`${activeBreak.date}T00:00:00Z`);
      nextDate.setUTCDate(nextDate.getUTCDate() + 1);
      breakDate = nextDate.toISOString().slice(0, 10);
    }
    breakStart = activeBreak.end;
    const extensionStart = new Date(workspaceInputToIso(`${breakDate}T${breakStart}`));
    defaultEnd = localTime(addMinutes(extensionStart, 30));
  }
  openDialog(extension ? 'Extend your current break' : 'Plan a break',
    extension ? 'The extension starts when your current break was due to end. You return to the queue when the extended window ends.' : 'A planned break removes you from the allocation queue only during its scheduled window.',
    `<div class="form-grid"><div class="field"><label for="break-date">Date</label><input id="break-date" name="date" type="date" required value="${breakDate}" /></div><div class="field"><label for="break-type">Break type</label><select id="break-type" name="breakType"><option value="bio">BioBreak</option><option value="meal">Meal break</option></select></div><div class="field"><label for="break-note">Note (optional)</label><input id="break-note" name="note" maxlength="100" value="${extension ? 'Break extension' : 'Scheduled break'}" /></div><div class="field"><label for="break-start">Start</label><input id="break-start" name="start" type="time" required value="${breakStart}" /></div><div class="field"><label for="break-end">End</label><input id="break-end" name="end" type="time" required value="${defaultEnd}" /></div></div>`,
    extension ? 'Extend break' : 'Save break', async (form) => {
      const item = { id: id(), memberId: currentMemberId, date: form.get('date'), start: form.get('start'), end: form.get('end'), note: form.get('note').trim(), breakType: form.get('breakType') || 'bio' };
      const error = validateTimeRange(item.start, item.end); if (error) throw new Error(error);
      if (!isBreakWithinShift(item, state.shifts)) throw new Error('The break must fit inside one of your scheduled shifts. Add your shift first or adjust the break window.');
      if (remoteMode) await rpc('add_break', { p_work_date: item.date, p_start: item.start, p_end: item.end, p_note: item.note || null, p_break_type: item.breakType });
      else { state.breaks.push(item); logActivity(`${currentMember().name} ${extension ? 'extended a break' : 'planned a break'} for ${prettyDate(item.date)}.`, '◷'); saveDemoState(); }
      await refreshAfterAction(extension ? 'Break extended. You will return to the queue when the extension ends.' : 'Break saved.');
    });
}

function openAllocationDialog(existingTicket = false) {
  if (!isCurrentAssignee()) return toast('Only the current shift assignee can record an allocation.', true);
  const queue = queueMembers(existingTicket);
  const target = queue[0];
  if (!target) return toast('No employee is currently eligible for allocation.', true);
  openDialog(existingTicket ? 'Route existing ticket' : 'Record new email', `The next eligible colleague is ${target.name}. ${existingTicket ? 'Existing tickets may be routed to colleagues in troubleshooting or meeting status.' : 'Only available colleagues can receive a new email.'} The queue advances immediately.`, `<div class="notice">Next recipient: <strong>${escapeHtml(target.name)}</strong>. Your name (${escapeHtml(currentMember().name)}) will be stored as the assigner.</div><div class="field"><label for="allocation-subject">Email subject (optional)</label><input id="allocation-subject" name="subject" maxlength="200" placeholder="e.g. VPN access issue - Bangalore team" /></div><div class="field" style="margin-top:12px"><label for="allocation-reference">Ticket / email reference (optional)</label><input id="allocation-reference" name="reference" maxlength="100" placeholder="e.g. INC0012345" /></div>`, 'Confirm assignment', async (form) => {
    const subject = form.get('subject').trim();
    const reference = form.get('reference').trim();
    if (remoteMode) await rpc('record_next_allocation', { p_reference: reference || null, p_subject: subject || null, p_existing_ticket: existingTicket });
    else {
      const result = recordAllocation({ lastAllocatedMemberId: state.lastAllocatedMemberId }, domainMembers(), { id: id(), assignedBy: currentMemberId, assignedAt: new Date().toISOString(), reference, emailSubject: subject, context: contextNow() });
      state.lastAllocatedMemberId = result.state.lastAllocatedMemberId;
      result.allocation.allocationKind = existingTicket ? 'existing_ticket' : 'new_email';
      state.allocations.unshift(result.allocation);
      logActivity(`${currentMember().name} assigned an email to ${target.name}${subject ? ` · ${subject}` : ''}.`, '⇄');
      saveDemoState();
    }
    await refreshAfterAction(`Email assignment recorded for ${target.name}.`);
  });
}

function openShiftSwapDialog() {
  const options = state.members.filter((member) => member.id !== currentMemberId && member.active !== false).map((member) => `<option value="${member.id}">${escapeHtml(member.name)}</option>`).join('');
  openDialog('Request a one-day shift swap', 'Choose a colleague who also has a shift on the same date. The swap is applied only after they accept.', `<div class="form-grid"><div class="field"><label for="swap-date">Work date</label><input id="swap-date" name="date" type="date" required value="${localDate()}" /></div><div class="field"><label for="swap-partner">Colleague</label><select id="swap-partner" name="partner" required><option value="">Choose colleague</option>${options}</select></div></div>`, 'Send swap request', async (form) => {
    const date = form.get('date'); const partnerId = form.get('partner');
    const mine = state.shifts.find((shift) => shift.memberId === currentMemberId && shift.date === date);
    const theirs = state.shifts.find((shift) => shift.memberId === partnerId && shift.date === date);
    if (!mine) throw new Error('You do not have a shift scheduled on that date.');
    if (!theirs) throw new Error('The selected colleague has no shift scheduled on that date.');
    if (remoteMode) await rpc('create_shift_swap_request', { p_partner_member_id: partnerId, p_work_date: date });
    else { state.shiftSwaps.unshift({ id: id(), requesterMemberId: currentMemberId, partnerMemberId: partnerId, workDate: date, status: 'pending', createdAt: new Date().toISOString() }); logActivity(`${currentMember().name} requested a shift swap with ${state.members.find((m) => m.id === partnerId)?.name}.`, '⇄'); saveDemoState(); }
    await refreshAfterAction('Shift swap request sent. It is not active until accepted.');
  });
}

async function respondShiftSwap(requestId, accept) {
  const swap = (state.shiftSwaps || []).find((item) => item.id === requestId);
  if (!swap || swap.partnerMemberId !== currentMemberId || swap.status !== 'pending') return toast('This shift swap is no longer awaiting your response.', true);
  try {
    if (remoteMode) await rpc('respond_shift_swap_request', { p_request_id: requestId, p_accept: accept });
    else {
      if (accept) {
        const left = state.shifts.find((shift) => shift.memberId === swap.requesterMemberId && shift.date === swap.workDate);
        const right = state.shifts.find((shift) => shift.memberId === swap.partnerMemberId && shift.date === swap.workDate);
        if (!left || !right) throw new Error('One of the scheduled shifts no longer exists.');
        const previous = { key: left.key, start: left.start, end: left.end };
        left.key = right.key; left.start = right.start; left.end = right.end;
        right.key = previous.key; right.start = previous.start; right.end = previous.end;
      }
      swap.status = accept ? 'accepted' : 'rejected'; swap.respondedAt = new Date().toISOString();
      logActivity(`${currentMember().name} ${accept ? 'accepted' : 'rejected'} a one-day shift swap.`, '⇄'); saveDemoState();
    }
    await refreshAfterAction(accept ? 'Shift swap accepted and applied.' : 'Shift swap rejected.');
  } catch (error) { toast(error.message || 'Unable to update shift swap.', true); }
}

async function takeOver() {
  if (isCurrentAssignee()) return toast('You already own allocation responsibility.');
  try {
    if (remoteMode) await rpc('take_over_allocation', {});
    else { const old = currentAssignee(); state.handovers.unshift({ id: id(), fromMemberId: state.currentAssigneeId, toMemberId: currentMemberId, createdAt: new Date().toISOString() }); state.currentAssigneeId = currentMemberId; logActivity(`${currentMember().name} took over allocation from ${old?.name || 'the previous assignee'}.`, '⇄'); saveDemoState(); }
    await refreshAfterAction('Allocation responsibility handed over to you. Pending requests are retained.');
  } catch (error) { toast(error.message, true); }
}

async function reviewRequest(requestId, decision) {
  if (!isCurrentAssignee()) return toast('Only the current assignee can review requests.', true);
  const request = state.requests.find((item) => item.id === requestId);
  if (!request || request.status !== 'pending') return toast('This request has already been reviewed.', true);
  const confirmation = window.prompt('Manager / SME / TL confirmation (optional):', '');
  if (confirmation === null) return;
  try {
    if (remoteMode) await rpc('review_availability_request', { p_request_id: requestId, p_decision: decision, p_confirmation: confirmation.trim() || null });
    else { request.status = decision; request.reviewedBy = currentMemberId; request.reviewedAt = new Date().toISOString(); request.confirmation = confirmation.trim() || null; logActivity(`${currentMember().name} ${decision} a request from ${state.members.find((m) => m.id === request.memberId)?.name || 'a team member'}.`, decision === 'approved' ? '✓' : '×'); saveDemoState(); }
    await refreshAfterAction(`Request ${decision}.`);
  } catch (error) { toast(error.message, true); }
}

async function refreshAfterAction(message) {
  if (remoteMode) await reloadRemote(); else renderApp();
  toast(message);
}
async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  if (realtimeChannel) { try { await realtimeChannel.send({ type: 'broadcast', event: 'refresh', payload: { source: name } }); } catch { /* RPC success must not be undone by a notification failure. */ } }
  return data;
}

function exportAllocations() {
  const rows = [['Recipient', 'Assigned by', 'Email subject', 'Assigned at (ISO timestamp)', 'Reference']];
  for (const item of state.allocations) rows.push([
    state.members.find((m) => m.id === item.memberId)?.name || '',
    state.members.find((m) => m.id === item.assignedBy)?.name || '', item.emailSubject || '', item.assignedAt, item.reference || '',
  ]);
  const csv = rows.map((row) => row.map((cell) => `"${String(cell).replace(/"/g, '""')}"`).join(',')).join('\r\n');
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob); const anchor = document.createElement('a');
  anchor.href = url; anchor.download = `whos-next-allocations-${localDate()}.csv`; anchor.click(); URL.revokeObjectURL(url);
}

function toast(message, error = false) {
  let element = $('.toast'); element?.remove();
  element = document.createElement('div'); element.className = `toast${error ? ' error' : ''}`; element.textContent = message;
  document.body.append(element); clearTimeout(toastTimer); toastTimer = setTimeout(() => element.remove(), 3500);
}

async function boot() {
  if (!remoteConfigured) {
    remoteMode = false;
    $('#app').innerHTML = '<main class="join-screen"><section class="join-card"><div class="brand"><span class="brand-mark">W</span><div class="brand-copy">WHO\'S <span>next</span></div></div><div class="eyebrow">Workspace setup</div><h1>Live workspace unavailable.</h1><p>This site is not connected to its Supabase workspace yet. No sample members or fake assignments are being shown.</p><div class="notice">The deployment must provide the Supabase project URL and publishable key before team members can sign in.</div><button class="button button-secondary" onclick="location.reload()">Retry connection</button></section></main>';
    return;
  }
  try { await connectRemote(); }
  catch (error) { $('#app').innerHTML = `<main class="join-screen"><section class="join-card"><h1>Workspace connection failed</h1><p>${escapeHtml(error.message || 'Unable to connect to Supabase.')}</p><div class="notice">Check the Supabase URL, publishable anon key, anonymous sign-in setting and database migration. No data has been changed locally.</div><button class="button button-secondary" onclick="location.reload()">Retry connection</button></section></main>`; }
}

boot();
