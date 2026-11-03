<p align="center">
  <img src="docs/assets/whos-next-logo.png" alt="WHO'S next logo" width="88" />
</p>

<h1 align="center">WHO'S next</h1>

<p align="center">
  <strong>A shift-aware team operations workspace for availability, handovers, and fair manual work allocation.</strong>
</p>

<p align="center">
  <a href="https://github.com/yashyp12/Who-s-Next/actions/workflows/ci.yml"><img src="https://github.com/yashyp12/Who-s-Next/actions/workflows/ci.yml/badge.svg" alt="CI status" /></a>
  <img src="https://img.shields.io/badge/Node.js-20%2B-339933?logo=node.js&logoColor=white" alt="Node.js 20 or newer" />
  <img src="https://img.shields.io/badge/Frontend-Vanilla%20JavaScript-F7DF1E?logo=javascript&logoColor=111" alt="Vanilla JavaScript" />
  <img src="https://img.shields.io/badge/Backend-Supabase-3ECF8E?logo=supabase&logoColor=white" alt="Supabase" />
  <img src="https://img.shields.io/badge/Hosting-Static%20site-00C7B7?logo=netlify&logoColor=white" alt="Static hosting compatible" />
</p>

WHO'S next helps a team coordinate shift coverage and manually distribute incoming email or ticket work. It provides one shared view of schedules, availability, requests, the current allocation owner, and the next eligible teammate.

**WHO'S next does not connect to mailboxes, read email, send messages, or measure ticket resolution.** A teammate performs the assignment in the team's existing mail or ticketing system and records the allocation in this workspace.

## Contents

- [Features](#features)
- [How allocation works](#how-allocation-works)
- [Architecture](#architecture)
- [Technology stack](#technology-stack)
- [Run locally](#run-locally)
- [Configure Supabase](#configure-supabase)
- [Database migrations and seed data](#database-migrations-and-seed-data)
- [Deploy the frontend](#deploy-the-frontend)
- [Testing](#testing)
- [Security and privacy](#security-and-privacy)
- [Known limitations](#known-limitations)
- [Contributing](#contributing)
- [License](#license)

## Features

### Shift and availability management
- Team roster with shift-aware presence and a live workspace clock.
- Configurable shift presets, including overnight shifts.
- Personal shift scheduling and planned break windows.
- Availability requests for meetings, knowledge transfer, troubleshooting, RDP issues, extended breaks, late login, early logout, leave, and other situations.
- Approval workflows with decision history and optional confirmation notes.
- One-day shift swaps that take effect after the invited teammate accepts.
- Shift check-in and check-out records.

### Allocation and handover
- Round-robin allocation based on roster order and the last successful allocation.
- Separate handling for new email assignments and existing-ticket routing.
- Server-side eligibility checks for shifts, breaks, approved requests, and active members.
- Transactional allocation writes to prevent concurrent actions from consuming the same turn.
- Explicit and automatic allocation handover with retained history.
- Allocation history and CSV export.

### Collaboration
- Realtime workspace refresh across connected browsers.
- In-app notifications and optional notification sound.
- Responsive layouts for desktop and mobile.
- Local demo mode for exploring the interface without a Supabase project.

## How allocation works

1. The dashboard identifies the current allocation owner and the next eligible teammate.
2. The owner assigns the work in the team's external email or ticketing system.
3. The owner records the assignment in WHO'S next, optionally adding a subject and reference.
4. The database validates the action and records the recipient, authenticated member attribution, and server timestamp.
5. The rotation advances immediately after a successful allocation transaction.

The queue is a convenience view, not an authorization boundary. Database functions re-check permissions and eligibility when an operation is submitted.

### Availability precedence

The application evaluates availability in this order:

1. Outside the scheduled shift: off shift.
2. Within approved leave: on leave.
3. Within approved temporary unavailability: unavailable.
4. Within a planned break: on break.
5. Otherwise: available.

Pending requests do not change eligibility. Approved requests affect only their approved time window. Overnight shifts belong to the date on which the shift starts.

Default shift presets in the application are examples. Confirm them against the team's actual coverage before using a live workspace:

| Preset | Start | End |
|---|---:|---:|
| Morning | 06:00 | 15:00 |
| Mid | 11:00 | 20:00 |
| Evening | 14:00 | 23:00 |
| Night | 22:00 | 07:00 next day |

## Architecture

WHO'S next is a static single-page application. It has no custom application server.

```text
Browser
  ├── HTML, CSS, vanilla JavaScript ES modules
  ├── Supabase client
  │     ├── Anonymous Auth session
  │     ├── Postgres tables and Row Level Security
  │     ├── Database RPCs for validated state changes
  │     └── Realtime Broadcast refresh events
  └── Static hosting (for example, Netlify)
```

The browser renders the workspace and requests authorized data. Supabase Postgres is the shared source of truth for live workspace state. Database RPCs perform sensitive state transitions, while Row Level Security limits direct data access. Realtime messages prompt connected clients to refresh; they are not relied upon to enforce correctness.

## Technology stack

| Area | Technology |
|---|---|
| Frontend | HTML, CSS, vanilla JavaScript ES modules |
| Shared state and authorization | Supabase Postgres, Row Level Security, SQL RPCs |
| Browser identity | Supabase Anonymous Auth |
| Live updates | Supabase Realtime |
| Static hosting | Netlify or another static host |
| Automated tests | Node.js built-in test runner |

## Run locally

### Requirements

- Node.js 20 or newer.
- Python 3 for the included static preview server.

### Install and start

Clone the repository:

```bash
git clone https://github.com/yashyp12/Who-s-Next.git
cd Who-s-Next
```

Run the test suite:

```bash
npm test
```

Start the static site:

```bash
npm run serve
```

Open <http://localhost:4173>.

Without a configured Supabase project, the application displays a setup state and does not fabricate live members or assignments. A configured workspace is required to use the shared operational features.

## Configure Supabase

For a shared workspace, create a Supabase project and configure it before deploying the frontend.

1. Enable **Anonymous Sign-Ins** in Supabase Authentication.
2. Review the SQL migrations in `supabase/migrations/`.
3. Apply the migrations to a new or intentionally selected project in filename order.
4. Customize `supabase/seed.sql` for the intended workspace, roster, shift coverage, and individual access-code placeholders.
5. Replace every seed access-code placeholder with a unique, random value of at least 16 characters. Never commit real access codes.
6. Configure the public Supabase project URL and publishable/anon key in `site/config.js`:

   ```js
   window.WHOS_NEXT_CONFIG = {
     supabaseUrl: 'https://YOUR-PROJECT.supabase.co',
     supabaseAnonKey: 'YOUR-PUBLISHABLE-OR-ANON-KEY',
   };
   ```

7. Confirm the required Realtime publication or Broadcast configuration described by the migrations.
8. Test with dedicated test profiles and separate browser sessions before inviting colleagues.

Only the public project URL and publishable/anon key belong in browser code. **Never place a Supabase service-role key, database password, private API key, or real member access code in the frontend or Git.**

If the application has no public Supabase configuration, it displays a setup state and does not create fake live members or allocations.

## Database migrations and seed data

Migrations are SQL files under `supabase/migrations/`. Apply them in lexical filename order to a fresh project. The current baseline sequence in this branch is:

```text
202611010001_initial_schema.sql
202611020001_individual_member_access_codes.sql
202611020002_allocation_timeline_shift_handover.sql
202611020003_expose_email_subject_in_dashboard.sql
202611020004_enforce_shift_owner_for_reviews.sql
202611020005_member_notifications.sql
202611020006_shift_aware_presence_and_ticket_routing.sql
202611020007_workspace_admin_controls.sql
202611020008_presence_break_roles.sql
202611020009_fix_workspace_refresh_trigger.sql
202611020010_request_withdrawal_and_takeover_guard.sql
202611020011_atomic_logout_handover.sql
202611020012_fix_withdrawal_lock_order.sql
```

This list describes the migration files included in this branch; check the repository before applying a migration to an existing database. Do not blindly re-run migrations against a live workspace. Back up production data, review each SQL change, and use a controlled deployment window.

The seed file contains sample roster entries and explicit placeholders. Customize it locally and keep real values private. Do not run the seed script repeatedly against an existing workspace unless you understand its upsert behavior and have reviewed the resulting data.

## Deploy the frontend

The frontend can be hosted on Netlify or any static hosting provider.

For Netlify, use:

| Setting | Value |
|---|---|
| Base directory | Repository root |
| Build command | None |
| Publish directory | `site` |

The deployed site must receive the public Supabase configuration expected by `site/config.js`. Keep environment-specific configuration out of source control. The static deployment does not apply database migrations or seed data; those are separate operator-managed steps.

After deployment, verify login, two-browser synchronization, shift boundaries, request approvals, allocation concurrency, handover, and mobile behavior before sharing the URL.

## Testing

Run:

```bash
npm test
```

The test suite uses Node's built-in test runner and does not require a third-party test framework. It covers scheduling and availability rules, allocation behavior, request handling, UI binding regressions, and other application invariants.

Before a live rollout, manually verify at least:

- [ ] A valid individual code maps to its intended active member; invalid codes are rejected.
- [ ] Two separate browsers can join as different members.
- [ ] Shift setup, edits, overnight shifts, and break boundaries behave correctly.
- [ ] Pending requests do not change availability; approved requests affect only their approved interval.
- [ ] Only authorized users can review requests or record allocations.
- [ ] Concurrent allocation attempts do not duplicate or skip a turn.
- [ ] Existing-ticket routing follows its separate eligibility rules.
- [ ] Allocation history records the recipient, assigner, timestamp, and optional reference.
- [ ] Explicit and automatic handovers retain the correct owner and history.
- [ ] Realtime refresh and notification behavior work across browsers.
- [ ] The app remains usable when notification audio is blocked by browser policy.
- [ ] Keyboard navigation, dialog cancellation, validation errors, and mobile layouts work.

## Security and privacy

The current identity model uses Supabase Anonymous Auth plus an individual access code that maps a browser session to a roster member. Access-code hashes are stored in Postgres; plaintext codes are supplied by the operator and must be shared privately.

This is a lightweight team identity mechanism, **not verified corporate authentication or SSO**. Anyone who obtains another member's access code may be able to act as that member. Browser storage/session clearing may require the member to re-enter their code. Use strong, unique codes and rotate a code immediately if it is exposed.

Do not use this application as the sole control for HR decisions, payroll, regulated records, sensitive personal information, or high-assurance security approvals. For stronger identity assurance and auditability, integrate verified organization-managed authentication and review the authorization model before use.

Operational data may include names, schedules, availability reasons, attendance events, and allocation history. Deployers are responsible for lawful collection, retention, access, backups, and deletion policies appropriate to their organization.

## Known limitations

- WHO'S next records manual allocation; it does not integrate with Outlook, Gmail, or ticketing systems.
- Allocation counts represent recorded assignments, not ticket closures, resolution quality, SLA compliance, or individual performance outcomes.
- Notification sound depends on browser permissions, autoplay restrictions, device audio settings, and the page's execution state.
- Local demo mode is isolated to one browser and is not a shared workspace.
- The access-code identity model is less robust than verified email authentication or SSO.

## Contributing

Contributions are welcome. To keep changes reviewable and safe:

1. Open an issue describing the problem or proposed change.
2. Create a focused branch from the latest `main`.
3. Keep pull requests small and avoid unrelated refactors.
4. Add or update automated tests for behavior changes.
5. Run `npm test` before opening the pull request.
6. Document any migration, configuration, or operational impact.
7. Never include real access codes, personal roster data, credentials, or production exports in commits or screenshots.

For database changes, explain the migration order, rollback considerations, and whether the change affects existing workspaces. Do not submit destructive schema changes without a clear migration and data-preservation plan.

## License

No license file is currently included in this repository. Until a license is added by the project owner, all rights are reserved by default and reuse, redistribution, and modification are not automatically permitted. If this project is intended to be open source, add an explicit license (for example, MIT or Apache-2.0) after choosing the terms that fit the project.
