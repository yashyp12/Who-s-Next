# Security and privacy notes

## Important boundary

WHO'S next is built for a small, trusted team that explicitly wants no individual login/logout workflow. It uses Supabase anonymous authentication behind the scenes, then an individual access code that maps to one roster profile. The roster profile is **not identity proof**. Anyone who obtains another colleague's code can impersonate that colleague, so the audit trail is operational traceability rather than cryptographic proof of which employee acted.

Do not store passwords, private customer data, medical details, disciplinary records, personal phone numbers, or any information that the team is not authorized to share in this workspace. Confirm employer policy before putting real staff availability or leave information into a personal project.

## Controls in this repository

- Browser code contains only the Supabase project URL and publishable/anon key. A service-role key must never be used in a browser.
- Each member's individual code is hashed with SHA-256 in Postgres in `member_access_codes`; plaintext codes must not be stored in the database or committed to this repository.
- Each real individual code must be kept out of Git and shared only with its matching colleague through an approved channel.
- Direct table grants are revoked from `anon` and `authenticated`; the app uses a narrow set of `SECURITY DEFINER` RPC functions.
- RLS is enabled on all operational tables.
- Request review and allocation functions validate the current-assignee mapping in the database.
- Allocation writes lock the workspace's allocation-state row to protect the sequence from concurrent requests.
- Every major operation writes an audit event.
- HTML content originating from user-entered values is escaped before rendering.
- Netlify response headers set basic browser security protections.

## Residual risks and required launch checks

1. An individual code can be forwarded or guessed. Use a unique random code (16+ characters) per colleague and replace the affected member's hash if it is exposed.
2. Browser anonymous identities are device/browser scoped. Clearing site data or moving to another device requires joining again. The colleague must re-enter their own individual code on that browser.
3. Selected roster identity can be impersonated by anyone with the team code. This is incompatible with HR-grade or disciplinary audit requirements.
4. Anonymous sign-ups can be abused to create Auth users. Supabase recommends CAPTCHA/anti-abuse protection for anonymous sign-in. Enable the provider's supported protections before broad exposure.
5. Database functions are security-sensitive. Review the migration and run all negative tests in a fresh Supabase project before using real data.
6. Supabase Free projects may pause after a week of low activity; Free is cost-controlled but not an uptime commitment. A paused project must be restored by the owner.
7. Netlify's Free plan has a monthly credit cap and may pause sites when it is reached. Do not enable paid auto-recharge or upgrade without approval.

## Stronger identity path

If verified employee accountability becomes necessary, replace shared-code profile selection with company SSO or verified individual identities, then bind `member_sessions.member_id` to the authenticated identity. Keep the same domain functions and allocation state model.
