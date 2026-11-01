# Delivery roadmap

## Foundation delivered in this repository baseline

- Product workflow and architecture documented.
- Responsive dashboard and local preview mode.
- Pure availability and round-robin domain logic with Node tests.
- Supabase schema, RLS posture, shared-code onboarding and server-side RPCs.
- Requests, approvals, handovers, allocations, shift swaps and audit records.
- Netlify static-hosting configuration and environment-safe public config placeholder.

## Next implementation / verification slices

### Slice 1 — Hosted workspace bootstrap

- Create Supabase Free project only after explicit approval.
- Apply migration and seed a fictional roster first.
- Verify RLS, anonymous sign-in, RPC permissions and cross-browser refresh.

### Slice 2 — Schedule completeness

- Bulk monthly shift entry/import for the 14-person roster.
- Break edit/cancel workflow with audit history.
- Employee shift swap notifications and cancellation.
- Shift overlap validation and team-level coverage warnings.

### Slice 3 — Operational completeness

- Reconcile attendance events with late-login/early-logout requests in a dedicated report.
- Extended-break actual-vs-planned duration report.
- Leave calendar and per-member filters.
- Manager/SME/TL confirmation choices instead of free-text notes if required.

### Slice 4 — Quality and production launch

- End-to-end browser tests across at least two sessions.
- Accessibility pass, mobile pass and timezone edge-case tests.
- Backup/export and retention policy agreed with the team.
- Deploy to Netlify Free after approval; monitor usage limits and pause behaviour.

## Explicit non-goals

- Direct Outlook mailbox access, email reading or sending.
- HR-grade attendance, payroll or disciplinary evidence.
- Verified employee identity while the no-login/shared-code model is retained.
- Paid cloud services, custom domains or paid add-ons without explicit approval.
