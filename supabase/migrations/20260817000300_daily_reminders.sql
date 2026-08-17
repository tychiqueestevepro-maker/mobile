create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;
create schema if not exists vault;
create extension if not exists supabase_vault with schema vault;

create or replace function private.validate_iana_timezone()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists(select 1 from pg_catalog.pg_timezone_names where name = new.timezone) then
    raise exception using errcode = '22023', message = 'Unknown IANA timezone';
  end if;
  return new;
end;
$$;

create trigger profiles_validate_timezone
  before insert or update of timezone on public.profiles
  for each row execute function private.validate_iana_timezone();
create trigger notification_preferences_validate_timezone
  before insert or update of timezone on public.notification_preferences
  for each row execute function private.validate_iana_timezone();

create or replace function public.enqueue_daily_list_reminders(p_now timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  due record;
  v_occurrence_id uuid;
  occurrence_count integer := 0;
begin
  for due in
    select
      np.user_id,
      l.id as list_id,
      (p_now at time zone np.timezone)::date as local_date,
      (((p_now at time zone np.timezone)::date + np.reminder_time) at time zone np.timezone) as scheduled_at
    from public.notification_preferences np
    join public.active_lists l on l.user_id = np.user_id and l.status = 'open'
    where np.daily_list_enabled
      and np.reminder_time <= (p_now at time zone np.timezone)::time
      and l.opened_at <= (((p_now at time zone np.timezone)::date + np.reminder_time) at time zone np.timezone)
      and exists (
        select 1 from public.active_list_items i where i.list_id = l.id and i.status = 'active'
      )
      and exists (
        select 1 from private.push_devices d where d.user_id = np.user_id and d.active
      )
      and not exists (
        select 1 from public.checkout_sessions c
        where c.list_id = l.id and c.state in ('processing', 'action_required', 'succeeded')
      )
  loop
    v_occurrence_id := null;
    insert into private.notification_occurrences(user_id, list_id, local_date, kind, scheduled_for)
    values(due.user_id, due.list_id, due.local_date, 'daily_list', due.scheduled_at)
    on conflict (user_id, list_id, local_date, kind) do nothing
    returning id into v_occurrence_id;
    if v_occurrence_id is not null then
      occurrence_count := occurrence_count + 1;
      insert into private.notification_jobs(occurrence_id, device_id)
      select v_occurrence_id, d.id from private.push_devices d
      where d.user_id = due.user_id and d.active
      on conflict (occurrence_id, device_id) do nothing;
    end if;
  end loop;
  return occurrence_count;
end;
$$;

create or replace function public.claim_notification_jobs(p_limit integer default 100)
returns table(
  job_id uuid,
  occurrence_id uuid,
  device_id uuid,
  token text,
  environment text,
  user_id uuid,
  list_id uuid,
  deep_link text,
  expiration_epoch bigint,
  attempts integer
)
language sql
security definer
set search_path = ''
as $$
  with obsolete as (
    update private.notification_jobs j
    set status = 'failed', last_error = 'Notification became obsolete before dispatch', updated_at = now()
    from private.notification_occurrences o
    where j.occurrence_id = o.id
      and (j.status in ('pending', 'retry') or (j.status = 'sending' and j.claimed_at < now() - interval '5 minutes'))
      and (
        not exists(select 1 from public.active_lists l where l.id = o.list_id and l.status = 'open')
        or not exists(select 1 from public.active_list_items i where i.list_id = o.list_id and i.status = 'active')
        or exists(select 1 from public.checkout_sessions c where c.list_id = o.list_id and c.state in ('processing', 'action_required', 'succeeded'))
      )
    returning j.id
  ), claimed as (
    select j.id
    from private.notification_jobs j
    join private.notification_occurrences o on o.id = j.occurrence_id
    join public.active_lists l on l.id = o.list_id and l.status = 'open'
    where (
      (j.status in ('pending', 'retry') and j.available_at <= now())
      or (j.status = 'sending' and j.claimed_at < now() - interval '5 minutes')
    )
      and exists(select 1 from public.active_list_items i where i.list_id = o.list_id and i.status = 'active')
      and not exists(select 1 from public.checkout_sessions c where c.list_id = o.list_id and c.state in ('processing', 'action_required', 'succeeded'))
    order by j.available_at, j.id
    limit greatest(1, least(p_limit, 500))
    for update skip locked
  ), updated as (
    update private.notification_jobs j
    set status = 'sending', attempts = j.attempts + 1, claimed_at = now(), updated_at = now()
    from claimed c where j.id = c.id
    returning j.*
  )
  select u.id, u.occurrence_id, u.device_id, d.token, d.environment,
         o.user_id, o.list_id, 'app://checkout?list_id=' || o.list_id::text,
         extract(epoch from (now() + interval '20 minutes'))::bigint, u.attempts
  from updated u
  join private.push_devices d on d.id = u.device_id and d.active
  join private.notification_occurrences o on o.id = u.occurrence_id;
$$;

create or replace function public.complete_notification_job(
  p_job_id uuid,
  p_outcome text,
  p_provider_message_id text default null,
  p_error text default null,
  p_invalidate_device boolean default false
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare target_device uuid;
begin
  if p_outcome not in ('accepted', 'retry', 'failed') then
    raise exception using errcode = '22023', message = 'Unsupported notification outcome';
  end if;
  update private.notification_jobs
  set status = p_outcome,
      provider_message_id = p_provider_message_id,
      last_error = left(p_error, 1000),
      available_at = case when p_outcome = 'retry'
        then now() + make_interval(secs => least(3600, (power(2, least(attempts, 10)) * 15)::integer))
        else available_at end,
      updated_at = now()
  where id = p_job_id
  returning device_id into target_device;
  if target_device is null then raise exception using errcode = 'P0002', message = 'Notification job not found'; end if;
  if p_invalidate_device then
    update private.push_devices set active = false, invalidated_at = now() where id = target_device;
  end if;
end;
$$;

-- The dispatcher URL and cron secret are read from Vault, never embedded in SQL.
-- Provision once per environment:
--   select vault.create_secret('https://<ref>.supabase.co/functions/v1/dispatch-daily-reminders', 'needs_dispatcher_url');
--   select vault.create_secret('<long random value>', 'needs_cron_secret');
create or replace function private.invoke_daily_reminder_dispatcher()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare dispatcher_url text; cron_secret text; request_id bigint;
begin
  select decrypted_secret into dispatcher_url from vault.decrypted_secrets where name = 'needs_dispatcher_url' limit 1;
  select decrypted_secret into cron_secret from vault.decrypted_secrets where name = 'needs_cron_secret' limit 1;
  if nullif(dispatcher_url, '') is null or nullif(cron_secret, '') is null then return null; end if;
  select net.http_post(
    url := dispatcher_url,
    headers := jsonb_build_object('content-type', 'application/json', 'x-cron-secret', cron_secret),
    body := jsonb_build_object('scheduled_at', now()),
    timeout_milliseconds := 10000
  ) into request_id;
  return request_id;
end;
$$;

do $$
begin
  if exists(select 1 from cron.job where jobname = 'needs-daily-list-reminders') then
    perform cron.unschedule('needs-daily-list-reminders');
  end if;
  perform cron.schedule(
    'needs-daily-list-reminders',
    '* * * * *',
    'select private.invoke_daily_reminder_dispatcher()'
  );
end;
$$;

revoke all on function public.enqueue_daily_list_reminders(timestamptz) from public, anon, authenticated;
revoke all on function public.claim_notification_jobs(integer) from public, anon, authenticated;
revoke all on function public.complete_notification_job(uuid, text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.enqueue_daily_list_reminders(timestamptz) to service_role;
grant execute on function public.claim_notification_jobs(integer) to service_role;
grant execute on function public.complete_notification_job(uuid, text, text, text, boolean) to service_role;
