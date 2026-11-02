<p align="center">
  <img src="docs/assets/whos-next-logo.png" alt="WHO'S next logo" width="96" />
</p>

<h1 align="center">WHO'S next</h1>

<p align="center">
  A shift-aware team presence dashboard and fair manual email-allocation workspace.
</p>

<p align="center">
  <a href="https://github.com/yashyp12/Who-s-Next/actions/workflows/ci.yml"><img src="https://github.com/yashyp12/Who-s-Next/actions/workflows/ci.yml/badge.svg" alt="CI status" /></a>
  <img src="https://img.shields.io/badge/runtime-Node.js%2020%2B-339933" alt="Node.js 20 or newer" />
  <img src="https://img.shields.io/badge/frontend-vanilla%20JavaScript-f7df1e" alt="Vanilla JavaScript" />
</p>

WHO'S next gives a multi-shift team one shared view of who is working, who is available, which requests need a decision, and who should receive the next manual email assignment. It records allocation decisions and history; it does **not** connect to Outlook, read mailboxes, or send emails.

## Contents

- [Product overview](#product-overview)
- [Core workflows](#core-workflows)
- [Allocation and availability rules](#allocation-and-availability-rules)
- [Identity and access model](#identity-and-access-model)
- [Run locally](#run-locally)
- [Connect a shared Supabase workspace](#connect-a-shared-supabase-workspace)
- [Deployment](#deployment)
- [Testing and acceptance checklist](#testing-and-acceptance-checklist)
- [Repository layout](#repository-layout)
- [Safety and production boundaries](#safety-and-production-boundaries)

## Product overview

The application is a static frontend built with vanilla JavaScript ES modules, HTML, and CSS. Supabase provides the shared Postgres database, anonymous browser sessions, RPCs, row-level security, and Realtime. Netlify can host the static `site/` directory.

The workspace supports:

- Allocation-first dashboard with the current responsibility owner and next eligible queue.
- Team availability derived from scheduled shifts, planned breaks, and approved requests.
- Monthly or daily shift entries, including overnight shifts and configurable presets.
- Typed BioBreak and Meal break scheduling, including active-break countdowns and five-minute reminders.
- Meeting, knowledge-transfer, technical issue, RDP issue, extended-break, late-login, early-logout, leave, and custom availability requests.
- Approval and rejection by the current allocation owner. Pending requests remain eligible until approved.
- Existing-ticket routing to colleagues in troubleshooting or meeting status while new email assignments require available status.
- One-day shift swaps that take effect only after the invited colleague accepts.
- Explicit allocation handover plus automatic handover when the owner leaves shift or becomes unavailable.
- Server-attributed allocation history with recipient, assigner, optional subject/reference, and precise timestamp.
- Realtime in-app notifications, optional sound, live refresh, workspace clock, reports, and CSV allocation export.
- Self-recorded shift check-in and check-out history.

## Core workflows

### Join the workspace

1. Open the deployed site.
2. The browser creates or restores a Supabase anonymous session.
3. On first use, enter the individual access code supplied privately by the workspace owner.
4. The server maps the code to the matching active roster member; the app does not show a roster picker.
5. If the member has no shift yet, the app opens first-time shift setup.

### Record an allocation

1. Open **Allocate** and confirm the current allocation owner and next eligible colleague.
2. Assign the email in Outlook or the team's external mail workflow.
3. Choose **Record new email** and optionally enter the subject and ticket/email reference.
4. The server validates the owner, shift, break, request, and rotation state.
5. The transaction records the recipient, authenticated member attribution, subject/reference, and server timestamp, then advances the pointer immediately.

Use **Route existing ticket** when the recipient is in troubleshooting or meeting status. Breaks, leave, off-shift members, and inactive members remain ineligible.

### Maintain availability

- Use **My profile** to add or edit your own shifts.
- Add BioBreak or Meal break windows that fit completely inside a scheduled shift.
- Submit an availability request with a reason and explicit start/end time.
- Pending requests do not change eligibility. Approved requests affect only their approved interval.
- During an active break, the allocation view shows the return time and a live countdown. A break-ending boundary refreshes the workspace automatically.

### Review and hand over

- Only the current allocation owner can approve or reject pending requests or record allocations.
- The owner cannot review their own request.
- Any mapped teammate may take over allocation responsibility.
- Automatic handover selects the most recently started eligible colleague when the owner leaves shift or becomes unavailable.
- Handover history is retained and pending requests remain available to the new owner.

## Allocation and availability rules

1. A member is eligible only during a scheduled shift.
2. Approved leave and approved temporary unavailability remove a member from the new-email queue for the approved interval.
3. A planned break removes a member only during its break window.
4. Pending requests do not remove a member from the queue.
5. The normal queue follows roster order after the last successful allocation and wraps around.
6. Skipping an ineligible member does not move the pointer.
7. A successful allocation advances the pointer immediately in the same database transaction; completion does not control rotation.
8. Existing tickets can be routed to available, troubleshooting, or meeting members, but not to members on break, leave, or off shift.
9. Operational timestamps use the workspace IANA timezone; the seed default is `Asia/Kolkata`.
10. The database re-checks eligibility and ownership at write time. The visible queue is not the security boundary.

Default shift presets are examples and must be confirmed for the team:

| Preset | Start | End |
|---|---:|---:|
| Morning | 06:00 | 15:00 |
| Mid | 11:00 | 20:00 |
| Evening | 14:00 | 23:00 |
| Night | 22:00 | 07:00 next day |

A night shift belongs to the date on which it starts.

## Identity and access model

WHO'S next intentionally has no username/password screen or logout button. Supabase creates a device-scoped anonymous browser session. The individual access code selects one active roster member through a server-side RPC; the code hash is stored in Postgres and direct table access is restricted.

This is a low-friction, trust-based identity model, not verified corporate authentication. Anyone who obtains another member's code can impersonate that member, and clearing browser data requires entering the code again. Do not use this system for disciplinary decisions, HR records, sensitive personal data, or security-critical approvals. Consider verified email authentication or SSO when stronger accountability is required.

## Run locally

### Requirements

- Node.js 20 or newer for tests.
- Python 3 for the static preview server.

### Commands

```bash
npm test
npm run serve
```

Open <http://localhost:4173>.

The local preview uses fictional browser-local data only and does not synchronize across devices. It includes a preview profile selector so the UI and core scheduling rules can be explored without a backend. Do not use preview data as production data.

## Connect a shared Supabase workspace

Do not run these steps against an existing production workspace without a backup, an approved change window, and an operator who understands the migration order.

1. Create a Supabase project.
2. In Authentication settings, enable **Anonymous Sign-Ins**.
3. Apply every migration in filename order:

   ```text
   supabase/migrations/202611010001_initial_schema.sql
   supabase/migrations/202611020001_individual_member_access_codes.sql
   supabase/migrations/202611020002_allocation_timeline_shift_handover.sql
   supabase/migrations/202611020003_expose_email_subject_in_dashboard.sql
   supabase/migrations/202611020004_enforce_shift_owner_for_reviews.sql
   supabase/migrations/202611020005_member_notifications.sql
   supabase/migrations/202611020006_shift_aware_presence_and_ticket_routing.sql
   supabase/migrations/202611020007_workspace_admin_controls.sql
   ```

4. Edit `supabase/seed.sql` locally with the real roster and one unique random access code per member. Use codes of at least 16 characters, keep them out of Git, and share each code only with its matching colleague.
5. Run the edited seed script once in the intended Supabase project.
6. Set only the public project URL and publishable/anon key in `site/config.js`:

   ```js
   window.WHOS_NEXT_CONFIG = {
     supabaseUrl: 'https://your-project.supabase.co',
     supabaseAnonKey: 'your-publishable-or-anon-key',
   };
   ```

   Never put a Supabase `service_role` key in browser code.
7. Confirm Realtime is enabled for the notification and workspace events required by the migrations.
8. Test the deployment with fictional or approved test members before sharing individual access codes.

If `site/config.js` has no public Supabase configuration, the app shows a clear unavailable/setup state and does not fabricate members or allocations.

## Deployment

Netlify can deploy this repository as a static site:

- **Publish directory:** `site`
- **Build command:** none
- **Required browser configuration:** `site/config.js` with the public Supabase URL and publishable/anon key

The repository does not deploy Supabase migrations, seed data, or backend functions. Apply and verify database changes separately before publishing the frontend.

## Testing and acceptance checklist

Run the automated suite:

```bash
npm test
```

The tests cover time-window boundaries, overnight shifts and breaks, availability precedence, pending requests, round-robin rotation, break return, ticket routing, typed breaks, validators, and duration formatting.

Before sharing a live workspace, verify:

- [ ] An invalid access code fails and each valid code maps to exactly one member.
- [ ] Two independent browsers can join as different members.
- [ ] First-time shift setup and later self-service shift editing work.
- [ ] Overnight shifts and breaks behave correctly around midnight.
- [ ] Pending requests leave a member eligible; approved requests remove them only in the approved interval.
- [ ] Non-owners cannot approve, reject, or record allocations.
- [ ] Two quick allocations do not duplicate or skip a turn.
- [ ] New email allocation excludes breaks and approved unavailability.
- [ ] Existing-ticket routing permits troubleshooting/meeting status but excludes breaks, leave, and off shift.
- [ ] Recipient, assigner, subject/reference, server timestamp, and next turn appear in the timeline and CSV export.
- [ ] Realtime updates reach another open browser and the UI remains usable if sound is blocked.
- [ ] Break reminders, active-break countdown, break expiry, and extension behave correctly.
- [ ] Automatic and explicit handovers preserve pending requests and owner history.
- [ ] A one-day shift swap changes only the selected date after acceptance.
- [ ] Check-in cannot be repeated before check-out, and check-out cannot occur before check-in.
- [ ] Mobile layout, keyboard navigation, refresh, and connection-error states work.

## Repository layout

```text
.
├── site/
│   ├── index.html
│   ├── config.js                  # public Supabase URL/key placeholders
│   └── src/
│       ├── app.mjs                # application orchestration and UI
│       ├── domain.mjs             # scheduling and allocation rules
│       ├── notifications.mjs      # in-app notifications and optional sound
│       └── styles.css             # responsive presentation
├── tests/
│   └── domain.test.mjs            # Node.js built-in test suite
├── supabase/
│   ├── migrations/                # ordered database schema/RPC/RLS changes
│   └── seed.sql                   # local/project setup seed; keep real codes private
├── docs/
│   ├── assets/whos-next-logo.png  # project branding
│   └── PRODUCT_SPEC.md            # product, workflow, and acceptance details
└── package.json
```

## Safety and production boundaries

- Never commit access codes, credentials, `.env` files, service-role keys, or private configuration.
- Never run production SQL, reset production data, or apply an unreviewed migration.
- Never disable or weaken tests to make a change pass.
- Never treat the client-visible queue as an authorization boundary.
- Never deploy Supabase or Netlify from an unreviewed local change.
- Preserve the server-side RPC and RLS checks when changing frontend behavior.

For detailed product behavior and the full two-browser acceptance flow, see [docs/PRODUCT_SPEC.md](docs/PRODUCT_SPEC.md).
