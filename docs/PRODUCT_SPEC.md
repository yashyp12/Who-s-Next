# WHO'S next — Product and workflow specification

## Product goal

Give a 14-person team across four shifts a single source of truth for schedules, availability, request approvals, the current allocation owner and manual email-allocation order.

## Roles

- **Team member:** manages their own shifts and breaks, submits availability/attendance requests, views team status, and can take over allocation responsibility.
- **Current email assignee:** all team-member capabilities plus request approval/rejection and recording of the next allocation.
- **No permanent administrator:** the allocation role changes by explicit handover. Initial roster and workspace setup are handled through the Supabase seed/configuration process, not a daily app administrator.

The app resolves the colleague's profile from their individual access code; no profile picker is shown. This remains a convenience identity, not verified corporate identity.

## Main user journey

1. Colleague opens the shared URL. A hidden anonymous browser session is created; there is no username/password or logout page.
2. First-use colleague enters their individual access code. The server maps it to exactly one active roster profile; the browser session remembers that mapping.
3. Colleague enters their schedule for the month and maintains planned breaks.
4. Colleague submits a meeting, KT, RDP/technical issue, extended break, late-login, early-logout, leave or other request with an explicit start/end window.
5. The request is visible as pending. Pending requests do not change availability.
6. The current email assignee reviews the request, records any manager/SME/TL confirmation, and approves or rejects it.
7. Approved requests affect availability only during the approved interval. Breaks affect availability only during their planned interval.
8. The dashboard calculates the eligible roster. The queue order is circular, based on roster `sort_order` and the last employee who actually received an allocation.
9. The current assignee manually allocates an email in Outlook (outside this application), then records the allocation in WHO'S next. The database records the recipient, assignee, timestamp and optional reference. The rotation pointer advances immediately in the same transaction as the successful allocation; email completion never gates the next assignment.
10. Any teammate can take over allocation responsibility. The previous and next assignee and the handover timestamp are retained. Pending approval requests are not reassigned or lost; the new owner sees the same pending queue.
11. A one-day shift swap is proposed by one colleague and applied only when the invited colleague accepts.
12. Employees can record lightweight shift check-in/check-out events. Reports read historical allocation, request, shift, attendance and handover records rather than only current status.

## Availability precedence

For the current workspace date/time:

1. Outside the employee's scheduled shift → **Off shift**.
2. Within approved leave → **On leave**.
3. Within approved temporary unavailability → reason-specific **Unavailable** status.
4. Within a planned break → **On break**.
5. Otherwise → **Available**.

The database allocation function applies the same schedule, approved-request and break checks at write time. It does not trust the visible queue alone.

## Allocation invariants

- Allocation state is stored centrally per workspace.
- `record_next_allocation` locks the allocation-state row before choosing a recipient. Two simultaneous clicks therefore cannot consume the same pointer position.
- The recipient is selected from active employees with a currently active shift, excluding anyone in an active planned break or approved request window.
- The next candidate is the first eligible roster member after the last allocation's `sort_order`, wrapping to the beginning.
- Skipping an ineligible person never modifies the pointer.
- The pointer advances immediately and only in the same database transaction that inserts an allocation record. Completion status is independent and must never advance or rewind the pointer.
- Only the currently mapped assignee can record an allocation.

## Shift conventions

Default presets are examples and must be confirmed by the team:

| Preset | Start | End |
|---|---:|---:|
| Morning | 06:00 | 15:00 |
| Mid | 11:00 | 20:00 |
| Evening | 14:00 | 23:00 |
| Night | 22:00 | 07:00 next day |

All stored shift times are local wall-clock times with a `work_date` and a workspace IANA timezone. A night shift belongs to the date on which it starts.

## Request types

- Meeting
- Knowledge transfer
- Technical issue
- RDP issue
- Extended break
- Late login
- Early logout
- Leave
- Other

Every request requires a reason, start and end. Leave should use the actual leave interval. Late-login/early-logout requests should describe only the interval that the employee will be unavailable, not the full shift.

## Realtime and concurrency

The frontend uses Supabase Realtime Broadcast notifications to ask connected browsers to reload their authorized dashboard snapshot after a write. Database functions remain the source of truth. The UI notification is not relied upon for correctness; a browser reload always fetches the latest snapshot.

## Acceptance checklist before sharing with colleagues

- [ ] Run the migration and edited seed script in a fresh Supabase project.
- [ ] Confirm each individual access code maps to exactly one member, an invalid code fails, and one member's code cannot select another profile.
- [ ] Open the app in two independent browsers and join as two different sample members.
- [ ] Enter overlapping shifts and verify overnight shift behaviour around midnight.
- [ ] Add a break and verify the employee drops out only during that interval.
- [ ] Submit a pending meeting request and verify the person remains eligible.
- [ ] Approve the request as current assignee and verify they are skipped only during its approved interval.
- [ ] Try approving as a non-assignee and verify the database rejects it.
- [ ] Record allocations from two browsers in quick succession and verify the round-robin pointer does not duplicate or skip a turn.
- [ ] Hand over allocation responsibility and verify the previous assignee can no longer approve or allocate.
- [ ] Accept a one-day shift swap as the invited colleague and verify only that date changes.
- [ ] Verify check-in cannot be repeated before check-out, and check-out cannot be recorded before check-in.
- [ ] Export allocation CSV and verify names, assignee and timestamps.
- [ ] Test mobile layout and refresh/reopen behaviour.
