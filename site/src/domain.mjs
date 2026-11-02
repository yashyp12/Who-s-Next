export const SHIFT_PRESETS = {
  morning: { label: 'Morning', start: '06:00', end: '15:00' },
  mid: { label: '11 AM – 8 PM', start: '11:00', end: '20:00' },
  evening: { label: '2 PM – 11 PM', start: '14:00', end: '23:00' },
  night: { label: 'Night', start: '22:00', end: '07:00' },
};

export const REQUEST_TYPES = {
  meeting: 'Meeting',
  kt: 'Knowledge transfer',
  technical: 'Troubleshooting',
  rdp: 'RDP issue',
  extended_break: 'Extended break',
  late_login: 'Late login',
  early_logout: 'Early logout',
  leave: 'Leave',
  other: 'Other',
};

const toMinutes = (value) => {
  if (typeof value !== 'string' || !/^\d{2}:\d{2}$/.test(value)) return NaN;
  const [h, m] = value.split(':').map(Number);
  if (h > 23 || m > 59) return NaN;
  return h * 60 + m;
};

export function isWithinTimeWindow(now, start, end) {
  const current = typeof now === 'number' ? now : toMinutes(now);
  const from = toMinutes(start);
  const until = toMinutes(end);
  if (![current, from, until].every(Number.isFinite)) return false;
  if (from === until) return true;
  return from < until ? current >= from && current < until : current >= from || current < until;
}

export function isWithinDateTimeRange(now, startAt, endAt) {
  const current = new Date(now).getTime();
  const start = new Date(startAt).getTime();
  const end = new Date(endAt).getTime();
  return [current, start, end].every(Number.isFinite) && current >= start && current < end;
}

export function getMemberStatus(member, context) {
  const { now, date, time } = context;
  const shift = member.shift;
  const previousDate = new Date(`${date}T00:00:00Z`);
  previousDate.setUTCDate(previousDate.getUTCDate() - 1);
  const previous = previousDate.toISOString().slice(0, 10);
  const shiftStart = shift ? toMinutes(shift.start) : NaN;
  const shiftEnd = shift ? toMinutes(shift.end) : NaN;
  const currentMinutes = toMinutes(time);
  const shiftStartsToday = shift?.date === date && Number.isFinite(shiftStart) && Number.isFinite(shiftEnd)
    && (shiftStart < shiftEnd ? currentMinutes >= shiftStart && currentMinutes < shiftEnd : currentMinutes >= shiftStart);
  const shiftContinuesToday = shift?.date === previous && Number.isFinite(shiftStart) && Number.isFinite(shiftEnd)
    && shiftStart > shiftEnd && currentMinutes < shiftEnd;
  if (!shiftStartsToday && !shiftContinuesToday) {
    return { code: 'off_shift', label: 'Off shift', tone: 'muted', returnAt: null, reason: 'Outside scheduled shift' };
  }

  const activeLeave = (member.requests || []).find((r) => r.type === 'leave' && r.status === 'approved' && isWithinDateTimeRange(now, r.startAt, r.endAt));
  if (activeLeave) return { code: 'leave', label: 'On leave', tone: 'danger', returnAt: activeLeave.endAt, reason: activeLeave.reason || 'Approved leave' };

  const unavailable = (member.requests || []).find((r) => r.status === 'approved' && r.type !== 'leave' && isWithinDateTimeRange(now, r.startAt, r.endAt));
  if (unavailable) {
    const severe = ['technical', 'rdp'].includes(unavailable.type);
    return { code: unavailable.type, label: ['technical','rdp','meeting'].includes(unavailable.type) ? 'Troubleshooting / Meeting' : (REQUEST_TYPES[unavailable.type] || 'Unavailable'), tone: severe ? 'danger' : 'warning', returnAt: unavailable.endAt, reason: unavailable.reason || REQUEST_TYPES[unavailable.type] };
  }

  const activeBreak = (member.breaks || []).find((b) => {
    const start = toMinutes(b.start); const end = toMinutes(b.end);
    if (![start, end, currentMinutes].every(Number.isFinite)) return false;
    if (b.date === date) return start < end ? currentMinutes >= start && currentMinutes < end : currentMinutes >= start;
    return b.date === previous && start > end && currentMinutes < end;
  });
  if (activeBreak) {
    const returnDate = activeBreak.start > activeBreak.end && time >= activeBreak.start
      ? new Date(Date.parse(`${activeBreak.date}T00:00:00Z`) + 86400000).toISOString().slice(0,10)
      : activeBreak.date;
    const breakLabel = activeBreak.breakType === 'meal' ? 'Meal break' : 'BioBreak';
    return { code: 'break', label: breakLabel, tone: 'warning', returnAt: `${returnDate}T${activeBreak.end}:00`, reason: breakLabel };
  }

  return { code: 'available', label: 'Available', tone: 'success', returnAt: null, reason: 'Eligible for allocation' };
}

export function getEligibleMembers(members, context) {
  return members
    .map((member) => ({ member, status: getMemberStatus(member, context) }))
    .filter(({ member, status }) => member.active !== false && status.code === 'available')
    .map(({ member }) => member)
    .sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0) || a.name.localeCompare(b.name));
}

export function getTicketEligibleMembers(members, context) {
  return members
    .map((member) => ({ member, status: getMemberStatus(member, context) }))
    .filter(({ member, status }) => member.active !== false
      && ['available', 'technical', 'rdp', 'meeting'].includes(status.code))
    .map(({ member }) => member)
    .sort((left, right) => (left.sortOrder ?? 0) - (right.sortOrder ?? 0)
      || left.name.localeCompare(right.name));
}

export function buildRotation(members, lastAllocatedMemberId, context = null) {
  if (!members.length) return [];
  const orderedRoster = [...members].sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0) || a.name.localeCompare(b.name));
  const eligibleIds = context
    ? new Set(getEligibleMembers(orderedRoster, context).map((member) => member.id))
    : new Set(orderedRoster.filter((member) => member.active !== false).map((member) => member.id));
  const lastIndex = orderedRoster.findIndex((member) => member.id === lastAllocatedMemberId);
  const rotated = lastIndex < 0
    ? orderedRoster
    : [...orderedRoster.slice(lastIndex + 1), ...orderedRoster.slice(0, lastIndex + 1)];
  return rotated.filter((member) => eligibleIds.has(member.id));
}

export function nextEligibleMember(members, lastAllocatedMemberId, context = null) {
  return buildRotation(members, lastAllocatedMemberId, context)[0] || null;
}

export function recordAllocation(state, members, allocation) {
  const next = nextEligibleMember(members, state.lastAllocatedMemberId, allocation.context);
  if (!next) throw new Error('No employees are currently eligible for allocation.');
  const entry = {
    id: allocation.id,
    memberId: next.id,
    assignedBy: allocation.assignedBy,
    assignedAt: allocation.assignedAt,
    reference: allocation.reference?.trim() || null,
    emailSubject: allocation.emailSubject?.trim() || null,
  };
  return {
    state: { ...state, lastAllocatedMemberId: next.id },
    allocation: entry,
  };
}

export function isBreakWithinShift(breakItem, shifts) {
  const minutes = (value) => {
    if (typeof value !== 'string' || !/^\d{2}:\d{2}$/.test(value)) return NaN;
    const [hours, mins] = value.split(':').map(Number);
    return hours <= 23 && mins <= 59 ? hours * 60 + mins : NaN;
  };
  const breakStartMinute = minutes(breakItem.start);
  const breakEndMinute = minutes(breakItem.end);
  if (!breakItem.date || !Number.isFinite(breakStartMinute) || !Number.isFinite(breakEndMinute) || breakStartMinute === breakEndMinute) return false;
  const toTimestamp = (date, minute) => Date.parse(`${date}T00:00:00Z`) + minute * 60000;
  const breakStart = toTimestamp(breakItem.date, breakStartMinute);
  const breakEnd = toTimestamp(breakItem.date, breakEndMinute + (breakEndMinute <= breakStartMinute ? 1440 : 0));
  return shifts.some((shift) => {
    if (shift.memberId !== breakItem.memberId) return false;
    const shiftStartMinute = minutes(shift.start);
    const shiftEndMinute = minutes(shift.end);
    if (!shift.date || !Number.isFinite(shiftStartMinute) || !Number.isFinite(shiftEndMinute) || shiftStartMinute === shiftEndMinute) return false;
    const shiftStart = toTimestamp(shift.date, shiftStartMinute);
    const shiftEnd = toTimestamp(shift.date, shiftEndMinute + (shiftEndMinute <= shiftStartMinute ? 1440 : 0));
    return breakStart >= shiftStart && breakEnd <= shiftEnd;
  });
}

export function validateTimeRange(start, end) {
  const from = toMinutes(start);
  const until = toMinutes(end);
  if (!Number.isFinite(from) || !Number.isFinite(until)) return 'Enter valid start and end times.';
  if (from === until) return 'Start and end times cannot be identical.';
  return null;
}

export function validateRequestPeriod(startAt, endAt) {
  const start = new Date(startAt).getTime();
  const end = new Date(endAt).getTime();
  if (!Number.isFinite(start) || !Number.isFinite(end)) return 'Enter valid start and end times.';
  if (end <= start) return 'End time must be after start time.';
  return null;
}

export function minutesBetween(start, end) {
  const a = new Date(start).getTime();
  const b = new Date(end).getTime();
  return Number.isFinite(a) && Number.isFinite(b) && b >= a ? Math.round((b - a) / 60000) : 0;
}

export function formatDuration(minutes) {
  const value = Math.max(0, Math.round(minutes || 0));
  const hours = Math.floor(value / 60);
  const remainder = value % 60;
  return hours ? `${hours}h ${remainder}m` : `${remainder}m`;
}

// Keep the status contract explicit for new-email and existing-ticket allocation.
