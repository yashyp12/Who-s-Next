-- Restore the original workspace owner as an administrator without changing
-- any existing member, session, or administrator assignments.
-- Idempotent: safe to apply more than once.

insert into public.workspace_admins (workspace_id, member_id)
select m.workspace_id, m.id
from public.members m
join public.workspaces w on w.id = m.workspace_id
where lower(trim(m.name)) = 'yash patil'
  and lower(trim(w.name)) = 'operations team'
  and m.active = true
on conflict (workspace_id, member_id) do nothing;
