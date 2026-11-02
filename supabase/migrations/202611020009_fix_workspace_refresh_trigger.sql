-- Repair the generic workspace refresh trigger after presence support.
-- Keep the presence-only optimization scoped to member_presence rows.
-- Avoid direct NEW.presence_state access: this trigger also runs on tables
-- whose row types do not contain that column.

create or replace function public.broadcast_workspace_refresh()
returns trigger
language plpgsql
security definer
set search_path = public, realtime, pg_temp
as $$
declare
  v_workspace_id uuid;
begin
  v_workspace_id := coalesce(
    nullif(to_jsonb(new)->>'workspace_id','')::uuid,
    nullif(to_jsonb(old)->>'workspace_id','')::uuid
  );

  if tg_table_name = 'member_presence' then
    if tg_op = 'UPDATE' then
      if (to_jsonb(new)->>'presence_state') is not distinct from (to_jsonb(old)->>'presence_state') then
        return null;
      end if;
    end if;
  end if;

  if v_workspace_id is not null then
    perform realtime.send(
      jsonb_build_object('table',tg_table_name,'operation',tg_op),
      'refresh',
      'whos-next-' || v_workspace_id::text,
      false
    );
  end if;
  return null;
end;
$$;

revoke execute on function public.broadcast_workspace_refresh() from public, anon;
grant execute on function public.broadcast_workspace_refresh() to authenticated;
