-- Replace the sample employee names and the workspace code before inviting colleagues.
-- Keep the real team code out of Git. This file intentionally uses a known placeholder.

insert into public.workspaces (id, name, timezone, join_code_hash)
values (
  '10000000-0000-4000-8000-000000000001',
  'Operations Team',
  'Asia/Kolkata',
  encode(extensions.digest('REPLACE-WITH-A-LONG-TEAM-CODE', 'sha256'), 'hex')
)
on conflict (id) do nothing;

insert into public.members (workspace_id, name, sort_order) values
('10000000-0000-4000-8000-000000000001', 'Team Member 01', 1),
('10000000-0000-4000-8000-000000000001', 'Team Member 02', 2),
('10000000-0000-4000-8000-000000000001', 'Team Member 03', 3),
('10000000-0000-4000-8000-000000000001', 'Team Member 04', 4),
('10000000-0000-4000-8000-000000000001', 'Team Member 05', 5),
('10000000-0000-4000-8000-000000000001', 'Team Member 06', 6),
('10000000-0000-4000-8000-000000000001', 'Team Member 07', 7),
('10000000-0000-4000-8000-000000000001', 'Team Member 08', 8),
('10000000-0000-4000-8000-000000000001', 'Team Member 09', 9),
('10000000-0000-4000-8000-000000000001', 'Team Member 10', 10),
('10000000-0000-4000-8000-000000000001', 'Team Member 11', 11),
('10000000-0000-4000-8000-000000000001', 'Team Member 12', 12),
('10000000-0000-4000-8000-000000000001', 'Team Member 13', 13),
('10000000-0000-4000-8000-000000000001', 'Team Member 14', 14)
on conflict (workspace_id, sort_order) do nothing;

insert into public.allocation_state (workspace_id)
values ('10000000-0000-4000-8000-000000000001')
on conflict (workspace_id) do nothing;

-- Add the first month's shift rows after editing employee names and shift coverage.
-- Suggested presets: morning 06:00-15:00, mid 11:00-20:00,
-- evening 14:00-23:00, night 22:00-07:00 (night shift ends next day).
