-- Replace sample employee names and all 14 individual-code placeholders before inviting colleagues.
-- The legacy workspace code is retained only for schema compatibility; the app no longer accepts it.

insert into public.workspaces (id, name, timezone, join_code_hash)
values (
  '10000000-0000-4000-8000-000000000001',
  'Operations Team',
  'Asia/Kolkata',
  encode(extensions.digest('LEGACY-CODE-DISABLED-AFTER-INDIVIDUAL-CODE-MIGRATION', 'sha256'), 'hex')
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


-- Give each colleague a separate code. Replace every placeholder with a unique
-- random value of at least 16 characters. Share each value privately with its owner.
-- Do not commit real codes or paste them into public issues.
insert into public.member_access_codes (workspace_id, member_id, access_code_hash)
select m.workspace_id, m.id, encode(extensions.digest(c.access_code, 'sha256'), 'hex')
from public.members m
join (values
  (1, 'REPLACE-WITH-INDIVIDUAL-CODE-01'),
  (2, 'REPLACE-WITH-INDIVIDUAL-CODE-02'),
  (3, 'REPLACE-WITH-INDIVIDUAL-CODE-03'),
  (4, 'REPLACE-WITH-INDIVIDUAL-CODE-04'),
  (5, 'REPLACE-WITH-INDIVIDUAL-CODE-05'),
  (6, 'REPLACE-WITH-INDIVIDUAL-CODE-06'),
  (7, 'REPLACE-WITH-INDIVIDUAL-CODE-07'),
  (8, 'REPLACE-WITH-INDIVIDUAL-CODE-08'),
  (9, 'REPLACE-WITH-INDIVIDUAL-CODE-09'),
  (10, 'REPLACE-WITH-INDIVIDUAL-CODE-10'),
  (11, 'REPLACE-WITH-INDIVIDUAL-CODE-11'),
  (12, 'REPLACE-WITH-INDIVIDUAL-CODE-12'),
  (13, 'REPLACE-WITH-INDIVIDUAL-CODE-13'),
  (14, 'REPLACE-WITH-INDIVIDUAL-CODE-14')
) as c(sort_order, access_code) on c.sort_order = m.sort_order
on conflict (member_id) do update
set access_code_hash = excluded.access_code_hash, updated_at = now();
