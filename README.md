# WHO'S next

**A shift-aware team availability and fair email-allocation workspace.**

WHO'S next gives a 14-person, multi-shift team one shared view of who is working, who is available, which requests need a decision, and who should receive the next manual email assignment.

> The application supports allocation decisions; it does not connect to Outlook, read mailboxes, or send emails.

## What is included

- Team availability dashboard with shift, break and approved-unavailability status.
- Monthly shift entries, including overnight shifts and configurable shift patterns.
- Planned daily breaks.
- Meeting, KT, technical issue, RDP issue, extended break, late login, early logout, leave and custom requests.
- Approval and rejection by the current email assignee. Pending requests do not remove a colleague from the queue.
- One-day shift swap requests that require the invited colleague's acceptance.
- Current-assignee handover with retained history.
- Lightweight shift check-in/check-out event capture and recent attendance history.
- Server-side round-robin allocation with a locked rotation pointer; skipped people do not advance the pointer.
- Allocation, request and handover history, plus CSV allocation export.
- No username/password screen and no logout button. The shared Supabase workspace uses an invisible anonymous browser session and an individual one-time access code.
- A local preview mode with fictional sample data so the UI and core allocation rules can be explored without creating a backend.

## Run the local preview

Requirements: Node.js 20+ (tests) and Python 3 (static server).

```bash
npm test
python -m http.server 4173 --directory site
```

Open `http://localhost:4173`. The preview stores its fictional data in this browser only; it does not synchronize across devices.

To preview as another fictional teammate, use the profile selector at the bottom of the sidebar.

## Connect the shared team workspace

The shared application uses Supabase Free for Postgres, anonymous sessions and Realtime. Netlify can host the static frontend on its Free plan. Free-plan availability is subject to provider quotas and may pause after inactivity; **free does not mean guaranteed production uptime**.

1. Create a Supabase project on the Free plan.
2. In Supabase Authentication settings, enable **Anonymous Sign-Ins**. There is no email, password or logout flow in this app.
3. Open the Supabase SQL Editor and run all migrations in order: `202611010001_initial_schema.sql`, `202611020001_individual_member_access_codes.sql`, `202611020002_allocation_timeline_shift_handover.sql`, and `202611020003_expose_email_subject_in_dashboard.sql`, and `202611020004_enforce_shift_owner_for_reviews.sql`.
4. Edit `supabase/seed.sql`: replace the 14 sample member names and all 14 individual-code placeholders in `supabase/seed.sql` with unique random codes of at least 16 characters. The legacy workspace code placeholder is unused after the second migration. Keep every real code out of Git and share each code privately with its matching colleague. Run the edited seed SQL once.
5. Set `supabaseUrl` and the **publishable/anon key** in `site/config.js`. Never use a Supabase `service_role` key in browser code.
6. Deploy the repository to Netlify with `site` as the publish directory. No build command is required.
7. Share the deployed URL with the team and give each colleague only their own individual access code. The code selects their profile automatically; no roster picker or password/account is shown.

### Identity and access model — read before using real team data

This project intentionally has no individual login/logout system. Supabase silently creates a browser-scoped anonymous user. Each colleague enters an individual code that maps to exactly one active roster member. The code is checked by a database function; its hash is stored in Postgres. Direct table access is revoked and changes are performed through database RPC functions.

This is a **low-friction, trust-based team identity model**, not verified employee authentication. Anyone who obtains another colleague's code can impersonate that colleague. Browser anonymous identities are device-scoped; clearing site data or switching devices requires entering that colleague's code again. Consequently, the audit trail records the selected profile, not a verified corporate identity. Do not use it for disciplinary decisions, HR records, sensitive personal data or security-critical approvals. For stronger accountability, the later upgrade path is individual SSO or verified email authentication.

## Operational rules

1. An employee is eligible only during a scheduled shift.
2. Approved leave and approved unavailability remove that employee from the queue for the approved time window.
3. A scheduled break removes the employee only during the break window.
4. A pending request does **not** affect eligibility.
5. The queue rotates through the full roster order after the last recorded recipient, skipping people who are currently ineligible. A successful allocation advances the pointer immediately in the same database transaction; completion does not control the rotation. Break expiry returns a colleague to their normal queue position automatically. A visible live clock shows workspace time to the second; the dashboard refreshes at the next scheduled shift, break or approved-request boundary to apply transitions without constant polling.
6. Only the current shift allocation owner can approve/reject requests or record the next allocation; the owner cannot decide their own request. Allocation responsibility automatically hands over when that owner leaves shift or becomes unavailable, selecting the most recently started eligible colleague.
7. Any mapped team member may take over allocation responsibility. Every handover is recorded, and pending requests remain pending for the new assignee.
8. Shift swaps affect one date only and are applied only after the invited colleague accepts.
9. All operational timestamps are interpreted in the workspace timezone (seed default: `Asia/Kolkata`).

## Repository layout

```text
.
├── site/
│   ├── index.html
│   ├── config.js                     # public Supabase URL/key placeholders
│   └── src/
│       ├── app.mjs                   # UI and application orchestration
│       ├── domain.mjs                # pure scheduling and allocation rules
│       └── styles.css
├── tests/domain.test.mjs
├── supabase/
│   ├── migrations/202611010001_initial_schema.sql
│   └── seed.sql
└── docs/
    ├── PRODUCT_SPEC.md
    ├── SECURITY.md
    └── ROADMAP.md
```

## Current delivery boundary

The local preview supports the main dashboard, schedule and break creation, availability requests, assignee handover, approval/rejection, round-robin recording, one-day shift swaps, check-in/check-out, reports and CSV export. The Supabase migration provides the shared-data RPCs and access controls for those workflows.

Before a real team launch, complete the Supabase setup above, enter the actual roster and monthly shift schedule, verify the database migration against the hosted project, and run the two-browser acceptance checklist in `docs/PRODUCT_SPEC.md`. No Supabase project or Netlify site is created by this repository commit.
