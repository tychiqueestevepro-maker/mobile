-- Narrow service-role bridges into the non-exposed private schema. PostgREST
-- exposes only public; execute privileges keep these functions server-only.
create or replace function public.memory_entries_for_ranking(p_user_id uuid)
returns table(
  category text, dimension text, value_key text, score numeric,
  positive_count integer, negative_count integer, numeric_value numeric, currency text
)
language sql stable security definer set search_path = '' as $$
  select e.category, e.dimension, e.value_key,
         round((e.score * power(0.5, greatest(0, extract(epoch from (now() - e.last_event_at))) / 86400.0 / 180.0))::numeric, 6),
         e.positive_count, e.negative_count, e.numeric_value, e.currency
  from private.preference_profile_entries e
  join public.profiles p on p.user_id = e.user_id and p.memory_epoch = e.memory_epoch
  where e.user_id = p_user_id and e.dimension not like 'price:%'
  union all
  select pe.category,
         'typical_price:' || coalesce(pe.dimensions ->> 'currency', 'USD') || ':' || coalesce(pe.dimensions ->> 'size_unit', 'item'),
         'median', 0::numeric, count(*)::integer, 0,
         percentile_cont(0.5) within group (order by (pe.dimensions ->> 'price_cents')::numeric)::numeric,
         coalesce(pe.dimensions ->> 'currency', 'USD')
  from private.preference_events pe
  join public.profiles p on p.user_id = pe.user_id and p.memory_epoch = pe.memory_epoch
  where pe.user_id = p_user_id and pe.weight > 0 and pe.dimensions ->> 'price_cents' is not null
  group by pe.category, coalesce(pe.dimensions ->> 'currency', 'USD'), coalesce(pe.dimensions ->> 'size_unit', 'item')
  having count(*) >= 3;
$$;

create or replace function public.register_push_device(
  p_user_id uuid,
  p_token text,
  p_environment text,
  p_app_version text default null,
  p_locale text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare result uuid;
begin
  if p_environment not in ('sandbox', 'production', 'mock') or nullif(p_token, '') is null then
    raise exception using errcode = '22023', message = 'Invalid push device';
  end if;
  insert into private.push_devices(user_id, token, environment, app_version, locale)
  values(p_user_id, p_token, p_environment, nullif(p_app_version, ''), nullif(p_locale, ''))
  on conflict (token, environment) do update set
    user_id = excluded.user_id, app_version = excluded.app_version, locale = excluded.locale,
    active = true, invalidated_at = null, last_seen_at = now()
  returning id into result;
  return result;
end;
$$;

create or replace function public.claim_webhook_event(
  p_provider text,
  p_external_event_id text,
  p_payload_hash text
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare affected integer;
begin
  insert into private.webhook_events(provider, external_event_id, payload_hash)
  values(lower(p_provider), p_external_event_id, p_payload_hash)
  on conflict (provider, external_event_id) do nothing;
  get diagnostics affected = row_count;
  return affected = 1;
end;
$$;

create or replace function public.begin_server_operation(
  p_user_id uuid,
  p_operation text,
  p_idempotency_key text,
  p_request_hash text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare existing private.idempotency_keys%rowtype; affected integer;
begin
  if nullif(p_operation, '') is null or nullif(p_idempotency_key, '') is null or nullif(p_request_hash, '') is null then
    raise exception using errcode = '22023', message = 'Invalid server operation';
  end if;
  insert into private.idempotency_keys(user_id, operation, idempotency_key, request_hash)
  values(p_user_id, p_operation, p_idempotency_key, p_request_hash)
  on conflict do nothing;
  get diagnostics affected = row_count;
  select * into existing from private.idempotency_keys
    where user_id = p_user_id and operation = p_operation and idempotency_key = p_idempotency_key for update;
  if existing.request_hash <> p_request_hash then
    raise exception using errcode = '22000', message = 'Idempotency key reused with different input';
  end if;
  if existing.status = 'completed' then
    return jsonb_build_object('started', false, 'status', 'completed', 'response', existing.response);
  end if;
  if affected = 1 or existing.status = 'failed' or existing.updated_at < now() - interval '5 minutes' then
    update private.idempotency_keys set status = 'processing', updated_at = now()
      where user_id = p_user_id and operation = p_operation and idempotency_key = p_idempotency_key;
    return jsonb_build_object('started', true, 'status', 'processing');
  end if;
  return jsonb_build_object('started', false, 'status', 'processing');
end;
$$;

create or replace function public.complete_server_operation(
  p_user_id uuid,
  p_operation text,
  p_idempotency_key text,
  p_response jsonb,
  p_succeeded boolean default true
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update private.idempotency_keys
    set status = case when p_succeeded then 'completed' else 'failed' end,
        response = p_response, updated_at = now()
    where user_id = p_user_id and operation = p_operation and idempotency_key = p_idempotency_key;
  if not found then raise exception using errcode = 'P0002', message = 'Server operation not found'; end if;
end;
$$;

revoke all on function public.memory_entries_for_ranking(uuid) from public, anon, authenticated;
revoke all on function public.register_push_device(uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.claim_webhook_event(text, text, text) from public, anon, authenticated;
revoke all on function public.begin_server_operation(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.complete_server_operation(uuid, text, text, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.memory_entries_for_ranking(uuid) to service_role;
grant execute on function public.register_push_device(uuid, text, text, text, text) to service_role;
grant execute on function public.claim_webhook_event(text, text, text) to service_role;
grant execute on function public.begin_server_operation(uuid, text, text, text) to service_role;
grant execute on function public.complete_server_operation(uuid, text, text, jsonb, boolean) to service_role;

-- Explicitly counter Supabase's broad default public-schema grants.
revoke insert, update, delete, truncate on public.retailers, public.products, public.product_offers,
  public.active_lists, public.active_list_items from anon, authenticated;
