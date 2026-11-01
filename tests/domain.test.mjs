import test from 'node:test';
import assert from 'node:assert/strict';
import {
  isWithinTimeWindow, getMemberStatus, getEligibleMembers,
  buildRotation, nextEligibleMember, recordAllocation,
  validateTimeRange, validateRequestPeriod, formatDuration,
} from '../site/src/domain.mjs';

const context = { now: '2026-11-01T12:00:00+05:30', date: '2026-11-01', time: '12:00' };
const member = (id, overrides = {}) => ({ id, name: id, active: true, sortOrder: Number(id.replace(/\D/g, '')) || 0, shift: { date: context.date, start: '06:00', end: '15:00' }, breaks: [], requests: [], ...overrides });

test('time windows include start and exclude end', () => {
  assert.equal(isWithinTimeWindow('09:00', '09:00', '10:00'), true);
  assert.equal(isWithinTimeWindow('10:00', '09:00', '10:00'), false);
});

test('overnight time windows cross midnight', () => {
  assert.equal(isWithinTimeWindow('23:30', '22:00', '07:00'), true);
  assert.equal(isWithinTimeWindow('06:59', '22:00', '07:00'), true);
  assert.equal(isWithinTimeWindow('07:00', '22:00', '07:00'), false);
});

test('availability prioritizes approved unavailability over breaks', () => {
  const employee = member('m1', { breaks: [{ date: context.date, start: '11:30', end: '12:30' }], requests: [{ type: 'technical', status: 'approved', startAt: '2026-11-01T11:45:00+05:30', endAt: '2026-11-01T12:30:00+05:30', reason: 'VPN issue' }] });
  assert.equal(getMemberStatus(employee, context).code, 'technical');
});

test('pending requests do not make employees unavailable', () => {
  const employee = member('m1', { requests: [{ type: 'meeting', status: 'pending', startAt: '2026-11-01T11:00:00+05:30', endAt: '2026-11-01T13:00:00+05:30' }] });
  assert.equal(getMemberStatus(employee, context).code, 'available');
});

test('approved breaks exclude members and eligibility is sorted', () => {
  const members = [member('m3'), member('m2', { breaks: [{ date: context.date, start: '11:00', end: '13:00' }] }), member('m1')];
  assert.deepEqual(getEligibleMembers(members, context).map((m) => m.id), ['m1', 'm3']);
});

test('rotation continues after the last allocation and wraps', () => {
  const members = [member('m1'), member('m2'), member('m3')];
  assert.deepEqual(buildRotation(members, 'm2').map((m) => m.id), ['m3', 'm1', 'm2']);
  assert.equal(nextEligibleMember(members, 'm3').id, 'm1');
});

test('recording an allocation advances the pointer exactly once', () => {
  const members = [member('m1'), member('m2')];
  const result = recordAllocation({ lastAllocatedMemberId: 'm1' }, members, { id: 'a1', assignedBy: 'operator', assignedAt: context.now, context });
  assert.equal(result.allocation.memberId, 'm2');
  assert.equal(result.state.lastAllocatedMemberId, 'm2');
  const withSubject = recordAllocation({ lastAllocatedMemberId: 'm1' }, members, { id: 'a2', assignedBy: 'operator', assignedAt: context.now, emailSubject: 'VPN access issue', context });
  assert.equal(withSubject.allocation.emailSubject, 'VPN access issue');
});

test('each successful allocation immediately advances the next recipient regardless of prior completion', () => {
  const members = [member('m1'), member('m2'), member('m3')];
  let allocationState = { lastAllocatedMemberId: null };
  const first = recordAllocation(allocationState, members, { id: 'a1', assignedBy: 'operator', assignedAt: context.now, reference: 'MAIL-001' });
  allocationState = first.state;
  const second = recordAllocation(allocationState, members, { id: 'a2', assignedBy: 'operator', assignedAt: context.now, reference: 'MAIL-002' });
  allocationState = second.state;
  const third = recordAllocation(allocationState, members, { id: 'a3', assignedBy: 'operator', assignedAt: context.now, reference: 'MAIL-003' });
  assert.deepEqual(
    [first.allocation.memberId, second.allocation.memberId, third.allocation.memberId],
    ['m1', 'm2', 'm3'],
  );
  assert.equal(third.state.lastAllocatedMemberId, 'm3');
});

test('time and request validators reject invalid ranges', () => {
  assert.match(validateTimeRange('12:00', '12:00'), /identical/);
  assert.equal(validateTimeRange('12:00', '13:00'), null);
  assert.match(validateRequestPeriod('2026-11-01T13:00:00', '2026-11-01T12:00:00'), /after/);
});

test('duration formatting is stable', () => {
  assert.equal(formatDuration(125), '2h 5m');
  assert.equal(formatDuration(40), '40m');
});

test('a colleague automatically returns to the eligible queue after their break ends', () => {
  const members = [
    member('m1'),
    member('m2', { breaks: [{ date: context.date, start: '11:00', end: '12:30' }] }),
    member('m3'),
  ];
  const duringBreak = { ...context, time: '12:00' };
  const afterBreak = { ...context, time: '12:30' };
  assert.deepEqual(buildRotation(members, 'm1', duringBreak).map((m) => m.id), ['m3', 'm1']);
  assert.deepEqual(buildRotation(members, 'm1', afterBreak).map((m) => m.id), ['m2', 'm3', 'm1']);
});

test('rotation skips unavailable employees without moving the pointer', () => {
  const members = [
    member('m1'),
    member('m2', { requests: [{ type: 'leave', status: 'approved', startAt: '2026-11-01T11:00:00+05:30', endAt: '2026-11-01T13:00:00+05:30' }] }),
    member('m3'),
  ];
  assert.deepEqual(buildRotation(members, 'm1', context).map((m) => m.id), ['m3', 'm1']);
});

test('rotation continues after a last recipient who is now unavailable', () => {
  const members = [member('m1'), member('m2'), member('m3'), member('m4', { breaks: [{ date: context.date, start: '11:00', end: '13:00' }] })];
  assert.deepEqual(buildRotation(members, 'm4', context).map((m) => m.id), ['m1', 'm2', 'm3']);
});


test('overnight shift is not active before its start date time', () => {
  const employee = member('night-1', { shift: { date: context.date, start: '22:00', end: '07:00' } });
  assert.equal(getMemberStatus(employee, { ...context, time: '06:30' }).code, 'off_shift');
  assert.equal(getMemberStatus(employee, { ...context, time: '22:30' }).code, 'available');
});

test('overnight shift remains active after midnight on the following date', () => {
  const employee = member('night-1', { shift: { date: '2026-10-31', start: '22:00', end: '07:00' } });
  assert.equal(getMemberStatus(employee, { now: '2026-11-01T06:30:00+05:30', date: '2026-11-01', time: '06:30' }).code, 'available');
  assert.equal(getMemberStatus(employee, { now: '2026-11-01T07:00:00+05:30', date: '2026-11-01', time: '07:00' }).code, 'off_shift');
});

test('overnight break starts only on its work date and continues after midnight', () => {
  const employee = member('night-1', {
    shift: { date: '2026-10-31', start: '22:00', end: '07:00' },
    breaks: [{ date: '2026-10-31', start: '23:30', end: '00:30', note: 'Night break' }],
  });
  assert.equal(getMemberStatus(employee, { now: '2026-10-31T23:00:00+05:30', date: '2026-10-31', time: '23:00' }).code, 'available');
  assert.equal(getMemberStatus(employee, { now: '2026-11-01T00:15:00+05:30', date: '2026-11-01', time: '00:15' }).code, 'break');
});

test('break must fit completely inside a scheduled shift', async () => {
  const { isBreakWithinShift } = await import('../site/src/domain.mjs');
  const shifts = [
    { memberId: 'm1', date: '2026-11-01', start: '09:00', end: '18:00' },
    { memberId: 'm2', date: '2026-11-01', start: '22:00', end: '07:00' },
  ];
  assert.equal(isBreakWithinShift({ memberId: 'm1', date: '2026-11-01', start: '12:00', end: '12:30' }, shifts), true);
  assert.equal(isBreakWithinShift({ memberId: 'm1', date: '2026-11-01', start: '18:00', end: '18:30' }, shifts), false);
  assert.equal(isBreakWithinShift({ memberId: 'm2', date: '2026-11-02', start: '00:30', end: '01:00' }, shifts), true);
  assert.equal(isBreakWithinShift({ memberId: 'm2', date: '2026-11-02', start: '07:00', end: '07:30' }, shifts), false);
});
