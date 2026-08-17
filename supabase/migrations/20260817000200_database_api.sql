create or replace function private.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare table_name text;
begin
  foreach table_name in array array[
    'profiles','addresses','retailers','products','product_offers','needs',
    'active_lists','active_list_items','notification_preferences','user_preferences',
    'checkout_sessions','orders','payments','retailer_orders','deliveries','subscriptions'
  ] loop
    execute format(
      'create trigger %I_touch_updated_at before update on public.%I for each row execute function private.touch_updated_at()',
      table_name, table_name
    );
  end loop;
end;
$$;

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  inferred_timezone text := coalesce(new.raw_user_meta_data ->> 'timezone', 'America/Los_Angeles');
begin
  insert into public.profiles(user_id, display_name, locale, timezone)
  values (
    new.id,
    nullif(new.raw_user_meta_data ->> 'display_name', ''),
    coalesce(nullif(new.raw_user_meta_data ->> 'locale', ''), 'en-US'),
    inferred_timezone
  ) on conflict (user_id) do nothing;

  insert into public.notification_preferences(user_id, timezone)
  values (new.id, inferred_timezone)
  on conflict (user_id) do nothing;

  insert into public.user_preferences(user_id) values (new.id)
  on conflict (user_id) do nothing;

  insert into public.active_lists(user_id)
  values (new.id)
  on conflict do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

create or replace function private.require_user()
returns uuid
language plpgsql stable
set search_path = ''
as $$
declare actor uuid := auth.uid();
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'Authentication required';
  end if;
  return actor;
end;
$$;

create or replace function private.require_epoch(p_user_id uuid, p_memory_epoch bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare current_epoch bigint;
begin
  select memory_epoch into current_epoch
  from public.profiles where user_id = p_user_id for update;
  if current_epoch is null then
    raise exception using errcode = 'P0002', message = 'Profile not found';
  end if;
  if p_memory_epoch is distinct from current_epoch then
    raise exception using
      errcode = '40001',
      message = 'Stale memory epoch',
      detail = jsonb_build_object('expected', current_epoch, 'received', p_memory_epoch)::text;
  end if;
  return current_epoch;
end;
$$;

create or replace function private.ensure_active_list(p_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare result uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('active-list:' || p_user_id::text, 0));
  select id into result from public.active_lists
    where user_id = p_user_id and status = 'open'
    order by opened_at desc limit 1 for update;
  if result is null then
    insert into public.active_lists(user_id) values (p_user_id) returning id into result;
  end if;
  return result;
end;
$$;

create or replace function private.upsert_preference_entry(
  p_user_id uuid,
  p_epoch bigint,
  p_category text,
  p_dimension text,
  p_value_key text,
  p_weight numeric,
  p_numeric_value numeric default null,
  p_currency text default null,
  p_at timestamptz default now()
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if nullif(trim(p_value_key), '') is null then return; end if;
  insert into private.preference_profile_entries(
    user_id, memory_epoch, category, dimension, value_key, score,
    positive_count, negative_count, numeric_value, currency, last_event_at
  ) values (
    p_user_id, p_epoch, lower(p_category), lower(p_dimension), lower(p_value_key), p_weight,
    case when p_weight > 0 then 1 else 0 end,
    case when p_weight < 0 then 1 else 0 end,
    p_numeric_value, p_currency, p_at
  )
  on conflict (user_id, memory_epoch, category, dimension, value_key) do update set
    score = round((
      private.preference_profile_entries.score * power(
        0.5,
        greatest(0, extract(epoch from (excluded.last_event_at - private.preference_profile_entries.last_event_at)))
          / 86400.0 / 180.0
      ) + excluded.score
    )::numeric, 6),
    positive_count = private.preference_profile_entries.positive_count + excluded.positive_count,
    negative_count = private.preference_profile_entries.negative_count + excluded.negative_count,
    numeric_value = coalesce(excluded.numeric_value, private.preference_profile_entries.numeric_value),
    currency = coalesce(excluded.currency, private.preference_profile_entries.currency),
    last_event_at = greatest(private.preference_profile_entries.last_event_at, excluded.last_event_at);
end;
$$;

create or replace function private.record_preference_event(
  p_user_id uuid,
  p_epoch bigint,
  p_category text,
  p_event_type text,
  p_weight numeric,
  p_product_id text,
  p_candidate_id uuid,
  p_dimensions jsonb,
  p_idempotency_key text,
  p_at timestamptz default now()
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  inserted_id uuid;
  attribute record;
  price_value numeric;
  price_bucket text;
begin
  insert into private.preference_events(
    user_id, memory_epoch, category, event_type, weight, product_id,
    candidate_id, dimensions, idempotency_key, occurred_at
  ) values (
    p_user_id, p_epoch, lower(p_category), p_event_type, p_weight, p_product_id,
    p_candidate_id, p_dimensions, p_idempotency_key, p_at
  ) on conflict (user_id, event_type, idempotency_key) do nothing
  returning id into inserted_id;
  if inserted_id is null then return false; end if;

  perform private.upsert_preference_entry(
    p_user_id, p_epoch, p_category, 'brand', coalesce(p_dimensions ->> 'brand', ''), p_weight, null, null, p_at
  );
  perform private.upsert_preference_entry(
    p_user_id, p_epoch, p_category, 'format', coalesce(p_dimensions ->> 'format', ''), p_weight, null, null, p_at
  );
  if p_dimensions ->> 'size_value' is not null and p_dimensions ->> 'size_unit' is not null then
    perform private.upsert_preference_entry(
      p_user_id, p_epoch, p_category, 'size',
      (p_dimensions ->> 'size_value') || ':' || lower(p_dimensions ->> 'size_unit'),
      p_weight, (p_dimensions ->> 'size_value')::numeric, null, p_at
    );
  end if;
  if jsonb_typeof(p_dimensions -> 'attributes') = 'object' then
    for attribute in select key, value from jsonb_each_text(p_dimensions -> 'attributes') loop
      perform private.upsert_preference_entry(
        p_user_id, p_epoch, p_category, 'attribute:' || attribute.key,
        attribute.value, p_weight, null, null, p_at
      );
    end loop;
  end if;
  if p_dimensions ->> 'price_cents' is not null then
    price_value := (p_dimensions ->> 'price_cents')::numeric;
    price_bucket := (round(price_value / 500.0) * 500)::bigint::text;
    perform private.upsert_preference_entry(
      p_user_id, p_epoch, p_category,
      'price:' || coalesce(p_dimensions ->> 'currency', 'USD') || ':' || coalesce(p_dimensions ->> 'size_unit', 'item'),
      price_bucket, p_weight, price_value, coalesce(p_dimensions ->> 'currency', 'USD'), p_at
    );
  end if;
  return true;
end;
$$;

create or replace function private.rebuild_preference_profile(p_user_id uuid, p_epoch bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  event_row record;
  attribute record;
  price_value numeric;
  price_bucket text;
begin
  delete from private.preference_profile_entries
    where user_id = p_user_id and memory_epoch = p_epoch;
  for event_row in
    select * from private.preference_events
    where user_id = p_user_id and memory_epoch = p_epoch
    order by occurred_at, id
  loop
    perform private.upsert_preference_entry(
      p_user_id, p_epoch, event_row.category, 'brand',
      coalesce(event_row.dimensions ->> 'brand', ''), event_row.weight, null, null, event_row.occurred_at
    );
    perform private.upsert_preference_entry(
      p_user_id, p_epoch, event_row.category, 'format',
      coalesce(event_row.dimensions ->> 'format', ''), event_row.weight, null, null, event_row.occurred_at
    );
    if event_row.dimensions ->> 'size_value' is not null and event_row.dimensions ->> 'size_unit' is not null then
      perform private.upsert_preference_entry(
        p_user_id, p_epoch, event_row.category, 'size',
        (event_row.dimensions ->> 'size_value') || ':' || lower(event_row.dimensions ->> 'size_unit'),
        event_row.weight, (event_row.dimensions ->> 'size_value')::numeric, null, event_row.occurred_at
      );
    end if;
    if jsonb_typeof(event_row.dimensions -> 'attributes') = 'object' then
      for attribute in select key, value from jsonb_each_text(event_row.dimensions -> 'attributes') loop
        perform private.upsert_preference_entry(
          p_user_id, p_epoch, event_row.category, 'attribute:' || attribute.key,
          attribute.value, event_row.weight, null, null, event_row.occurred_at
        );
      end loop;
    end if;
    if event_row.dimensions ->> 'price_cents' is not null then
      price_value := (event_row.dimensions ->> 'price_cents')::numeric;
      price_bucket := (round(price_value / 500.0) * 500)::bigint::text;
      perform private.upsert_preference_entry(
        p_user_id, p_epoch, event_row.category,
        'price:' || coalesce(event_row.dimensions ->> 'currency', 'USD') || ':' || coalesce(event_row.dimensions ->> 'size_unit', 'item'),
        price_bucket, event_row.weight, price_value,
        coalesce(event_row.dimensions ->> 'currency', 'USD'), event_row.occurred_at
      );
    end if;
  end loop;
end;
$$;

create or replace function public.confirm_selection(
  p_candidate_id uuid,
  p_quantity integer,
  p_idempotency_key text,
  p_memory_epoch bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_user();
  candidate public.product_candidates%rowtype;
  target_list uuid;
  item_id uuid;
  dimensions jsonb;
  request_hash text;
  idem private.idempotency_keys%rowtype;
  result jsonb;
begin
  if p_quantity not between 1 and 99 or nullif(p_idempotency_key, '') is null then
    raise exception using errcode = '22023', message = 'Invalid quantity or idempotency key';
  end if;
  perform private.require_epoch(actor, p_memory_epoch);
  select * into candidate from public.product_candidates
    where id = p_candidate_id and user_id = actor for update;
  if candidate.id is null then raise exception using errcode = 'P0002', message = 'Candidate not found'; end if;
  if not candidate.available then raise exception using errcode = 'P0001', message = 'Product is unavailable'; end if;

  request_hash := encode(extensions.digest(
    concat_ws(':', p_candidate_id::text, p_quantity::text, p_memory_epoch::text), 'sha256'
  ), 'hex');
  insert into private.idempotency_keys(user_id, operation, idempotency_key, request_hash)
    values (actor, 'confirm_selection', p_idempotency_key, request_hash)
    on conflict do nothing;
  select * into idem from private.idempotency_keys
    where user_id = actor and operation = 'confirm_selection' and idempotency_key = p_idempotency_key
    for update;
  if idem.request_hash <> request_hash then
    raise exception using errcode = '22000', message = 'Idempotency key reused with different input';
  end if;
  if idem.status = 'completed' then return idem.response; end if;

  target_list := private.ensure_active_list(actor);
  select id into item_id from public.active_list_items
    where list_id = target_list and product_id = candidate.product_id and status = 'active' for update;
  dimensions := jsonb_build_object(
    'brand', candidate.brand, 'format', candidate.format,
    'size_value', candidate.size_value, 'size_unit', candidate.size_unit,
    'unit_count', candidate.unit_count, 'attributes', candidate.attributes,
    'price_cents', candidate.price_cents, 'currency', candidate.currency
  );
  if item_id is null then
    insert into public.active_list_items(
      list_id, user_id, need_id, candidate_id, product_id, offer_id, retailer_id,
      product_snapshot, quantity
    ) values (
      target_list, actor, candidate.need_id, candidate.id, candidate.product_id,
      candidate.offer_id, candidate.retailer_id,
      jsonb_build_object(
        'id', candidate.product_id, 'name', candidate.name, 'brand', candidate.brand,
        'category', candidate.category, 'format', candidate.format,
        'size_value', candidate.size_value, 'size_unit', candidate.size_unit,
        'unit_count', candidate.unit_count, 'attributes', candidate.attributes,
        'price_cents', candidate.price_cents, 'currency', candidate.currency,
        'retailer_id', candidate.retailer_id
      ), p_quantity
    ) returning id into item_id;
  else
    update public.active_list_items
      set quantity = least(99, quantity + p_quantity), updated_at = now()
      where id = item_id;
  end if;
  perform private.record_preference_event(
    actor, p_memory_epoch, candidate.category, 'selection', 1,
    candidate.product_id, candidate.id, dimensions, p_idempotency_key
  );
  insert into public.selected_products(
    user_id, need_id, candidate_id, list_item_id, product_id, quantity
  ) values (
    actor, candidate.need_id, candidate.id, item_id, candidate.product_id, p_quantity
  ) on conflict (user_id, candidate_id) do update set
    quantity = least(99, public.selected_products.quantity + excluded.quantity),
    list_item_id = excluded.list_item_id,
    selected_at = now();
  update public.needs set status = 'selected' where id = candidate.need_id and user_id = actor;
  result := jsonb_build_object(
    'list_id', target_list, 'item_id', item_id, 'memory_epoch', p_memory_epoch,
    'recorded_signal', 'selection'
  );
  update private.idempotency_keys set status = 'completed', response = result, updated_at = now()
    where user_id = actor and operation = 'confirm_selection' and idempotency_key = p_idempotency_key;
  return result;
end;
$$;

create or replace function public.reject_product_candidate(
  p_candidate_id uuid,
  p_idempotency_key text,
  p_memory_epoch bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_user();
  candidate public.product_candidates%rowtype;
  dimensions jsonb;
  recorded boolean;
begin
  if nullif(p_idempotency_key, '') is null then
    raise exception using errcode = '22023', message = 'Idempotency key is required';
  end if;
  perform private.require_epoch(actor, p_memory_epoch);
  select * into candidate from public.product_candidates
    where id = p_candidate_id and user_id = actor;
  if candidate.id is null then raise exception using errcode = 'P0002', message = 'Candidate not found'; end if;
  dimensions := jsonb_build_object(
    'brand', candidate.brand, 'format', candidate.format,
    'size_value', candidate.size_value, 'size_unit', candidate.size_unit,
    'attributes', candidate.attributes, 'price_cents', candidate.price_cents,
    'currency', candidate.currency
  );
  recorded := private.record_preference_event(
    actor, p_memory_epoch, candidate.category, 'rejection', -1,
    candidate.product_id, candidate.id, dimensions, p_idempotency_key
  );
  return jsonb_build_object('candidate_id', candidate.id, 'recorded', recorded, 'memory_epoch', p_memory_epoch);
end;
$$;

create or replace function public.update_active_list_item(
  p_item_id uuid,
  p_action text,
  p_quantity integer,
  p_idempotency_key text,
  p_memory_epoch bigint,
  p_candidate_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_user();
  item public.active_list_items%rowtype;
  candidate public.product_candidates%rowtype;
  category text;
  recorded boolean := false;
  request_hash text;
  idem private.idempotency_keys%rowtype;
  result jsonb;
begin
  if p_action not in ('remove', 'replace', 'set_quantity', 'carry_forward') then
    raise exception using errcode = '22023', message = 'Unsupported list action';
  end if;
  if nullif(p_idempotency_key, '') is null then
    raise exception using errcode = '22023', message = 'Idempotency key required';
  end if;
  perform private.require_epoch(actor, p_memory_epoch);
  request_hash := encode(extensions.digest(concat_ws(
    ':', p_item_id::text, p_action, coalesce(p_quantity::text, ''),
    coalesce(p_candidate_id::text, ''), p_memory_epoch::text
  ), 'sha256'), 'hex');
  insert into private.idempotency_keys(user_id, operation, idempotency_key, request_hash)
    values(actor, 'update_active_list', p_idempotency_key, request_hash) on conflict do nothing;
  select * into idem from private.idempotency_keys
    where user_id = actor and operation = 'update_active_list' and idempotency_key = p_idempotency_key for update;
  if idem.request_hash <> request_hash then raise exception using errcode = '22000', message = 'Idempotency key reused with different input'; end if;
  if idem.status = 'completed' then return idem.response; end if;

  select i.* into item from public.active_list_items i
    join public.active_lists l on l.id = i.list_id
    where i.id = p_item_id and i.user_id = actor and l.status = 'open' and i.status = 'active'
    for update of i;
  if item.id is null then raise exception using errcode = 'P0002', message = 'Active list item not found'; end if;
  if p_action = 'set_quantity' then
    if p_quantity not between 1 and 99 then raise exception using errcode = '22023', message = 'Invalid quantity'; end if;
    update public.active_list_items set quantity = p_quantity where id = item.id;
  elsif p_action = 'carry_forward' then
    update public.active_list_items set carry_forward = true where id = item.id;
  elsif p_action = 'replace' then
    if p_candidate_id is null then raise exception using errcode = '22023', message = 'Replacement candidate required'; end if;
    select * into candidate from public.product_candidates
      where id = p_candidate_id and user_id = actor for update;
    if candidate.id is null then raise exception using errcode = 'P0002', message = 'Replacement candidate not found'; end if;
    if not candidate.available then raise exception using errcode = 'P0001', message = 'Replacement product is unavailable'; end if;
    recorded := private.record_preference_event(
      actor, p_memory_epoch, coalesce(item.product_snapshot ->> 'category', 'other'),
      'replacement', -1, item.product_id, item.candidate_id, item.product_snapshot,
      'replace-old:' || p_idempotency_key
    );
    update public.active_list_items set
      need_id = candidate.need_id,
      candidate_id = candidate.id,
      product_id = candidate.product_id,
      offer_id = candidate.offer_id,
      retailer_id = candidate.retailer_id,
      product_snapshot = jsonb_build_object(
        'id', candidate.product_id, 'name', candidate.name, 'brand', candidate.brand,
        'category', candidate.category, 'format', candidate.format,
        'size_value', candidate.size_value, 'size_unit', candidate.size_unit,
        'unit_count', candidate.unit_count, 'attributes', candidate.attributes,
        'price_cents', candidate.price_cents, 'currency', candidate.currency,
        'retailer_id', candidate.retailer_id
      ),
      quantity = coalesce(p_quantity, item.quantity),
      carry_forward = false
    where id = item.id;
    perform private.record_preference_event(
      actor, p_memory_epoch, candidate.category, 'selection', 1,
      candidate.product_id, candidate.id,
      jsonb_build_object(
        'brand', candidate.brand, 'format', candidate.format,
        'size_value', candidate.size_value, 'size_unit', candidate.size_unit,
        'unit_count', candidate.unit_count, 'attributes', candidate.attributes,
        'price_cents', candidate.price_cents, 'currency', candidate.currency
      ), 'replace-new:' || p_idempotency_key
    );
    insert into public.selected_products(user_id, need_id, candidate_id, list_item_id, product_id, quantity)
    values(actor, candidate.need_id, candidate.id, item.id, candidate.product_id, coalesce(p_quantity, item.quantity))
    on conflict (user_id, candidate_id) do update set
      list_item_id = excluded.list_item_id, quantity = excluded.quantity, selected_at = now();
    update public.needs set status = 'selected' where id = candidate.need_id and user_id = actor;
  else
    update public.active_list_items set status = 'removed', removed_at = now() where id = item.id;
    category := coalesce(item.product_snapshot ->> 'category', 'other');
    recorded := private.record_preference_event(
      actor, p_memory_epoch, category, 'removal', -0.25,
      item.product_id, item.candidate_id, item.product_snapshot, p_idempotency_key
    );
  end if;
  result := jsonb_build_object(
    'item_id', item.id, 'action', p_action, 'recorded', recorded,
    'candidate_id', p_candidate_id, 'memory_epoch', p_memory_epoch
  );
  update private.idempotency_keys set status = 'completed', response = result, updated_at = now()
    where user_id = actor and operation = 'update_active_list' and idempotency_key = p_idempotency_key;
  return result;
end;
$$;

create or replace function public.reset_product_memory(p_expected_epoch bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare actor uuid := private.require_user(); new_epoch bigint;
begin
  perform private.require_epoch(actor, p_expected_epoch);
  update public.profiles set memory_epoch = memory_epoch + 1 where user_id = actor
    returning memory_epoch into new_epoch;
  delete from private.preference_events where user_id = actor;
  delete from private.preference_profile_entries where user_id = actor;
  return jsonb_build_object('memory_epoch', new_epoch, 'reset', true);
end;
$$;

create or replace function public.remove_learned_preference(
  p_category text,
  p_dimension text,
  p_value_key text,
  p_expected_epoch bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare actor uuid := private.require_user(); new_epoch bigint; removed_count integer;
begin
  perform private.require_epoch(actor, p_expected_epoch);
  select count(*) into removed_count from private.preference_profile_entries
    where user_id = actor and memory_epoch = p_expected_epoch
      and category = lower(p_category) and dimension = lower(p_dimension)
      and (value_key = lower(p_value_key) or (dimension like 'price:%' and lower(p_value_key) = 'typical'));
  if removed_count = 0 then raise exception using errcode = 'P0002', message = 'Learned preference not found'; end if;

  -- Purge source events that contain the removed dimension. Remaining history is
  -- moved to the next epoch so stale offline writes cannot resurrect the deletion.
  delete from private.preference_events e
    where e.user_id = actor and e.memory_epoch = p_expected_epoch and e.category = lower(p_category)
      and case
        when lower(p_dimension) = 'brand' then lower(coalesce(e.dimensions ->> 'brand', '')) = lower(p_value_key)
        when lower(p_dimension) = 'format' then lower(coalesce(e.dimensions ->> 'format', '')) = lower(p_value_key)
        when lower(p_dimension) = 'size' then
          lower(coalesce(e.dimensions ->> 'size_value', '') || ':' || coalesce(e.dimensions ->> 'size_unit', '')) = lower(p_value_key)
        when lower(p_dimension) like 'attribute:%' then
          lower(coalesce(e.dimensions -> 'attributes' ->> split_part(p_dimension, ':', 2), '')) = lower(p_value_key)
        when lower(p_dimension) like 'price:%' and lower(p_value_key) = 'typical' then
          coalesce(e.dimensions ->> 'currency', 'USD') = split_part(p_dimension, ':', 2)
          and coalesce(e.dimensions ->> 'size_unit', 'item') = split_part(p_dimension, ':', 3)
        when lower(p_dimension) like 'price:%' then
          coalesce(e.dimensions ->> 'currency', 'USD') = split_part(p_dimension, ':', 2)
          and coalesce(e.dimensions ->> 'size_unit', 'item') = split_part(p_dimension, ':', 3)
          and (round((e.dimensions ->> 'price_cents')::numeric / 500.0) * 500)::bigint::text = p_value_key
        else false
      end;
  update public.profiles set memory_epoch = memory_epoch + 1 where user_id = actor returning memory_epoch into new_epoch;
  update private.preference_events set memory_epoch = new_epoch where user_id = actor and memory_epoch = p_expected_epoch;
  delete from private.preference_profile_entries where user_id = actor;
  perform private.rebuild_preference_profile(actor, new_epoch);
  return jsonb_build_object('memory_epoch', new_epoch, 'removed', true);
end;
$$;

create or replace function public.create_checkout_session(
  p_selected_item_ids uuid[],
  p_offer_overrides jsonb,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_user();
  current_list uuid;
  item public.active_list_items%rowtype;
  chosen_offer public.product_offers%rowtype;
  override_id uuid;
  request_hash text;
  idem private.idempotency_keys%rowtype;
  session_id uuid;
  subtotal integer := 0;
  service_fee integer := 0;
  delivery_fee integer := 0;
  tax integer := 0;
  pricing_lines jsonb := '[]'::jsonb;
  result jsonb;
  selected_count integer := 0;
  expected_count integer;
  service_fee_discount_bps integer := 0;
begin
  if coalesce(cardinality(p_selected_item_ids), 0) = 0 or nullif(p_idempotency_key, '') is null then
    raise exception using errcode = '22023', message = 'At least one item and an idempotency key are required';
  end if;
  if cardinality(p_selected_item_ids) <> (select count(distinct x) from unnest(p_selected_item_ids) x) then
    raise exception using errcode = '22023', message = 'Duplicate item identifiers';
  end if;
  expected_count := cardinality(p_selected_item_ids);
  select id into current_list from public.active_lists
    where user_id = actor and status = 'open' for update;
  if current_list is null then raise exception using errcode = 'P0002', message = 'Open list not found'; end if;
  select case when subscription_tier = 'plus' and (plus_expires_at is null or plus_expires_at > now())
    then 200 else 0 end into service_fee_discount_bps
  from public.profiles where user_id = actor;

  request_hash := encode(extensions.digest(
    p_selected_item_ids::text || ':' || coalesce(p_offer_overrides, '{}'::jsonb)::text, 'sha256'
  ), 'hex');
  insert into private.idempotency_keys(user_id, operation, idempotency_key, request_hash)
    values (actor, 'create_checkout', p_idempotency_key, request_hash) on conflict do nothing;
  select * into idem from private.idempotency_keys
    where user_id = actor and operation = 'create_checkout' and idempotency_key = p_idempotency_key for update;
  if idem.request_hash <> request_hash then raise exception using errcode = '22000', message = 'Idempotency key reused with different input'; end if;
  if idem.status = 'completed' then return idem.response; end if;

  for item in select * from public.active_list_items
    where user_id = actor and list_id = current_list and status = 'active' and id = any(p_selected_item_ids)
    order by id for update
  loop
    selected_count := selected_count + 1;
    begin
      override_id := nullif(p_offer_overrides ->> item.id::text, '')::uuid;
    exception when invalid_text_representation then
      raise exception using errcode = '22023', message = 'Invalid offer override';
    end;
    select * into chosen_offer from public.product_offers
      where id = coalesce(override_id, item.offer_id) and product_id = item.product_id and available for update;
    if chosen_offer.id is null or (chosen_offer.inventory_count is not null and chosen_offer.inventory_count < item.quantity) then
      raise exception using errcode = 'P0001', message = 'A selected product is unavailable', detail = item.id::text;
    end if;
    update public.active_list_items set
      offer_id = chosen_offer.id,
      retailer_id = chosen_offer.retailer_id,
      product_snapshot = product_snapshot || jsonb_build_object(
        'price_cents', chosen_offer.price_cents, 'currency', chosen_offer.currency,
        'retailer_id', chosen_offer.retailer_id
      ) where id = item.id;
    subtotal := subtotal + chosen_offer.price_cents * item.quantity;
    pricing_lines := pricing_lines || jsonb_build_array(jsonb_build_object(
      'item_id', item.id, 'product_id', item.product_id, 'offer_id', chosen_offer.id,
      'retailer_id', chosen_offer.retailer_id, 'quantity', item.quantity,
      'unit_price_cents', chosen_offer.price_cents
    ));
  end loop;
  if selected_count <> expected_count then raise exception using errcode = 'P0002', message = 'One or more active items were not found'; end if;

  select coalesce(sum(ceil(s.retailer_subtotal * greatest(0, r.service_fee_bps - service_fee_discount_bps) / 10000.0)), 0)::integer,
         coalesce(sum(case when r.free_delivery_threshold_cents is not null
                               and s.retailer_subtotal >= r.free_delivery_threshold_cents
                           then 0 else r.delivery_fee_cents end), 0)::integer
  into service_fee, delivery_fee
  from (
    select i.retailer_id, sum(o.price_cents * i.quantity)::integer retailer_subtotal
    from public.active_list_items i join public.product_offers o on o.id = i.offer_id
    where i.id = any(p_selected_item_ids) group by i.retailer_id
  ) s join public.retailers r on r.id = s.retailer_id;

  insert into public.checkout_sessions(
    user_id, list_id, selected_item_ids, pricing_snapshot, subtotal_cents,
    service_fee_cents, delivery_fee_cents, tax_cents, currency, idempotency_key
  ) values (
    actor, current_list, p_selected_item_ids,
    jsonb_build_object('lines', pricing_lines, 'calculated_at', now(), 'service_fee_discount_bps', service_fee_discount_bps),
    subtotal, service_fee, delivery_fee, tax, 'USD', p_idempotency_key
  ) returning id into session_id;
  result := jsonb_build_object(
    'id', session_id, 'list_id', current_list, 'state', 'ready', 'lines', pricing_lines,
    'subtotal_cents', subtotal, 'service_fee_cents', service_fee,
    'delivery_fee_cents', delivery_fee, 'tax_cents', tax,
    'total_cents', subtotal + service_fee + delivery_fee + tax, 'currency', 'USD'
  );
  update private.idempotency_keys set status = 'completed', response = result, updated_at = now()
    where user_id = actor and operation = 'create_checkout' and idempotency_key = p_idempotency_key;
  return result;
end;
$$;

create or replace function public.confirm_checkout_payment(
  p_checkout_session_id uuid,
  p_payment_reference text,
  p_provider_state text,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_user();
  checkout public.checkout_sessions%rowtype;
  v_order_id uuid;
  next_list_id uuid;
  item record;
  current_epoch bigint;
  request_hash text;
  idem private.idempotency_keys%rowtype;
  result jsonb;
begin
  if p_provider_state not in ('authorized', 'action_required', 'failed') or nullif(p_idempotency_key, '') is null then
    raise exception using errcode = '22023', message = 'Invalid payment result';
  end if;
  request_hash := encode(extensions.digest(
    concat_ws(':', p_checkout_session_id::text, p_payment_reference, p_provider_state), 'sha256'
  ), 'hex');
  insert into private.idempotency_keys(user_id, operation, idempotency_key, request_hash)
    values(actor, 'confirm_payment', p_idempotency_key, request_hash) on conflict do nothing;
  select * into idem from private.idempotency_keys
    where user_id = actor and operation = 'confirm_payment' and idempotency_key = p_idempotency_key for update;
  if idem.request_hash <> request_hash then raise exception using errcode = '22000', message = 'Idempotency key reused with different input'; end if;
  if idem.status = 'completed' then return idem.response; end if;

  select * into checkout from public.checkout_sessions
    where id = p_checkout_session_id and user_id = actor for update;
  if checkout.id is null then raise exception using errcode = 'P0002', message = 'Checkout not found'; end if;
  if checkout.state = 'succeeded' then
    select id into v_order_id from public.orders where checkout_session_id = checkout.id;
    result := jsonb_build_object('checkout_id', checkout.id, 'order_id', v_order_id, 'state', 'succeeded');
  elsif p_provider_state <> 'authorized' then
    update public.checkout_sessions set
      state = case when p_provider_state = 'action_required' then 'action_required'::public.checkout_state else 'failed'::public.checkout_state end,
      failure_code = p_provider_state, payment_reference = p_payment_reference
      where id = checkout.id;
    insert into public.payments(
      user_id, checkout_session_id, state, provider_reference, amount_cents,
      currency, idempotency_key, failure_code
    ) values (
      actor, checkout.id,
      case when p_provider_state = 'action_required' then 'action_required'::public.payment_state else 'failed'::public.payment_state end,
      p_payment_reference, checkout.total_cents, checkout.currency, p_idempotency_key, p_provider_state
    ) on conflict (user_id, idempotency_key) do nothing;
    result := jsonb_build_object('checkout_id', checkout.id, 'state', p_provider_state);
  else
    update public.checkout_sessions set state = 'processing', payment_reference = p_payment_reference where id = checkout.id;
    select memory_epoch into current_epoch from public.profiles where user_id = actor;
    insert into public.orders(
      user_id, list_id, checkout_session_id, subtotal_cents, service_fee_cents,
      delivery_fee_cents, tax_cents, total_cents, currency
    ) values (
      actor, checkout.list_id, checkout.id, checkout.subtotal_cents, checkout.service_fee_cents,
      checkout.delivery_fee_cents, checkout.tax_cents, checkout.total_cents, checkout.currency
    ) returning id into v_order_id;
    insert into public.payments(
      user_id, checkout_session_id, order_id, state, provider_reference,
      amount_cents, currency, idempotency_key
    ) values (
      actor, checkout.id, v_order_id, 'captured', p_payment_reference,
      checkout.total_cents, checkout.currency, p_idempotency_key
    ) on conflict (user_id, idempotency_key) do update set
      order_id = excluded.order_id, state = excluded.state;

    insert into public.order_items(
      order_id, user_id, list_item_id, product_id, retailer_id, product_snapshot,
      quantity, unit_price_cents
    )
    select v_order_id, actor, i.id, i.product_id, i.retailer_id, i.product_snapshot,
           i.quantity, o.price_cents
    from public.active_list_items i join public.product_offers o on o.id = i.offer_id
    where i.id = any(checkout.selected_item_ids) and i.user_id = actor and i.status = 'active';

    for item in select i.* from public.active_list_items i
      where i.id = any(checkout.selected_item_ids) and i.user_id = actor and i.status = 'active' for update
    loop
      update public.active_list_items set status = 'purchased', purchased_at = now() where id = item.id;
      perform private.record_preference_event(
        actor, current_epoch, coalesce(item.product_snapshot ->> 'category', 'other'),
        'purchase', 1, item.product_id, item.candidate_id, item.product_snapshot,
        'purchase:' || checkout.id::text || ':' || item.id::text
      );
    end loop;

    insert into public.retailer_orders(order_id, user_id, retailer_id, subtotal_cents)
    select v_order_id, actor, retailer_id, sum(unit_price_cents * quantity)::integer
    from public.order_items where public.order_items.order_id = v_order_id group by retailer_id;

    update public.active_lists set status = 'checked_out', completed_at = now() where id = checkout.list_id;
    if exists(select 1 from public.active_list_items where list_id = checkout.list_id and status = 'active') then
      insert into public.active_lists(user_id) values(actor) returning id into next_list_id;
      update public.active_list_items set list_id = next_list_id, carry_forward = false
        where list_id = checkout.list_id and status = 'active';
    end if;
    update public.checkout_sessions set state = 'succeeded' where id = checkout.id;
    result := jsonb_build_object(
      'checkout_id', checkout.id, 'order_id', v_order_id, 'state', 'succeeded',
      'next_list_id', next_list_id
    );
  end if;
  update private.idempotency_keys set status = 'completed', response = result, updated_at = now()
    where user_id = actor and operation = 'confirm_payment' and idempotency_key = p_idempotency_key;
  return result;
end;
$$;

-- User-readable projection; raw behavioral events remain in private.
create or replace function public.learned_preferences_summary()
returns table(
  id uuid, category text, dimension text, value_key text, score numeric,
  positive_count integer, negative_count integer, typical_price_cents numeric,
  lower_price_cents numeric, upper_price_cents numeric, currency text, memory_epoch bigint
)
language sql
security definer
set search_path = ''
stable
as $$
  with entries as (
    select e.*
    from private.preference_profile_entries e
    join public.profiles p on p.user_id = e.user_id and p.memory_epoch = e.memory_epoch
    where e.user_id = private.require_user()
  ), non_price as (
    select e.id, e.category, e.dimension, e.value_key,
           round((e.score * power(0.5, greatest(0, extract(epoch from (now() - e.last_event_at))) / 86400.0 / 180.0))::numeric, 4) score,
           e.positive_count, e.negative_count, null::numeric typical_price_cents,
           null::numeric lower_price_cents, null::numeric upper_price_cents,
           e.currency, e.memory_epoch
    from entries e where e.dimension not like 'price:%'
  ), price_groups as (
    select min(e.id) id, e.user_id, e.category, e.dimension, 'typical'::text value_key,
           round(sum(e.score), 4) score, sum(e.negative_count)::integer negative_count,
           max(e.currency) currency, e.memory_epoch
    from entries e where e.dimension like 'price:%'
    group by e.user_id, e.category, e.dimension, e.memory_epoch
  ), price_summaries as (
    select g.id, g.category, g.dimension, g.value_key, g.score,
           s.signal_count::integer positive_count, g.negative_count,
           s.median_price::numeric typical_price_cents,
           s.lower_price::numeric lower_price_cents,
           s.upper_price::numeric upper_price_cents,
           g.currency, g.memory_epoch
    from price_groups g
    cross join lateral (
      select count(*) signal_count,
             percentile_cont(0.5) within group (order by (pe.dimensions ->> 'price_cents')::numeric) median_price,
             percentile_cont(0.25) within group (order by (pe.dimensions ->> 'price_cents')::numeric) lower_price,
             percentile_cont(0.75) within group (order by (pe.dimensions ->> 'price_cents')::numeric) upper_price
      from private.preference_events pe
      where pe.user_id = g.user_id and pe.memory_epoch = g.memory_epoch
        and pe.category = g.category and pe.weight > 0
        and pe.dimensions ->> 'price_cents' is not null
        and coalesce(pe.dimensions ->> 'currency', 'USD') = split_part(g.dimension, ':', 2)
        and coalesce(pe.dimensions ->> 'size_unit', 'item') = split_part(g.dimension, ':', 3)
    ) s
    where s.signal_count >= 3
  )
  select * from non_price
  union all
  select * from price_summaries
  order by category, dimension, score desc;
$$;

create or replace function public.has_plus_entitlement()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(subscription_tier = 'plus' and (plus_expires_at is null or plus_expires_at > now()), false)
  from public.profiles where user_id = private.require_user();
$$;

-- RLS -----------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.addresses enable row level security;
alter table public.retailers enable row level security;
alter table public.products enable row level security;
alter table public.product_offers enable row level security;
alter table public.needs enable row level security;
alter table public.product_candidates enable row level security;
alter table public.active_lists enable row level security;
alter table public.active_list_items enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.user_preferences enable row level security;
alter table public.need_attributes enable row level security;
alter table public.selected_products enable row level security;
alter table public.checkout_sessions enable row level security;
alter table public.orders enable row level security;
alter table public.payments enable row level security;
alter table public.order_items enable row level security;
alter table public.retailer_orders enable row level security;
alter table public.deliveries enable row level security;
alter table public.delivery_events enable row level security;
alter table public.subscriptions enable row level security;

create policy profiles_owner_select on public.profiles for select to authenticated using (user_id = auth.uid());
create policy profiles_owner_update on public.profiles for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy addresses_owner_all on public.addresses for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy retailers_authenticated_read on public.retailers for select to authenticated using (active);
create policy products_authenticated_read on public.products for select to authenticated using (active);
create policy offers_authenticated_read on public.product_offers for select to authenticated using (true);
create policy needs_owner_all on public.needs for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy candidates_owner_all on public.product_candidates for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy lists_owner_select on public.active_lists for select to authenticated using (user_id = auth.uid());
create policy list_items_owner_select on public.active_list_items for select to authenticated using (user_id = auth.uid());
create policy notification_preferences_owner_all on public.notification_preferences for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy user_preferences_owner_all on public.user_preferences for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy need_attributes_owner_select on public.need_attributes for select to authenticated using (user_id = auth.uid());
create policy selected_products_owner_select on public.selected_products for select to authenticated using (user_id = auth.uid());
create policy checkouts_owner_select on public.checkout_sessions for select to authenticated using (user_id = auth.uid());
create policy orders_owner_select on public.orders for select to authenticated using (user_id = auth.uid());
create policy payments_owner_select on public.payments for select to authenticated using (user_id = auth.uid());
create policy order_items_owner_select on public.order_items for select to authenticated using (user_id = auth.uid());
create policy retailer_orders_owner_select on public.retailer_orders for select to authenticated using (user_id = auth.uid());
create policy deliveries_owner_select on public.deliveries for select to authenticated using (user_id = auth.uid());
create policy delivery_events_owner_select on public.delivery_events for select to authenticated using (user_id = auth.uid());
create policy subscriptions_owner_select on public.subscriptions for select to authenticated using (user_id = auth.uid());

grant usage on schema public to authenticated;
revoke insert, update, delete, truncate on public.profiles, public.needs, public.need_attributes,
  public.product_candidates, public.selected_products, public.checkout_sessions, public.orders,
  public.order_items, public.payments, public.retailer_orders, public.deliveries,
  public.delivery_events, public.subscriptions from anon, authenticated;
grant select, insert, update, delete on public.addresses, public.notification_preferences, public.user_preferences to authenticated;
grant select, insert on public.needs, public.need_attributes, public.product_candidates to service_role;
grant select on public.profiles, public.retailers, public.products, public.product_offers,
  public.needs, public.need_attributes, public.product_candidates, public.selected_products,
  public.active_lists, public.active_list_items, public.checkout_sessions, public.orders,
  public.order_items, public.payments, public.retailer_orders, public.deliveries,
  public.delivery_events, public.subscriptions to authenticated;
revoke update on public.profiles from anon, authenticated;
grant update(display_name, locale, currency, timezone, onboarding_completed_at) on public.profiles to authenticated;

revoke all on function public.confirm_selection(uuid, integer, text, bigint) from public, anon;
revoke all on function public.reject_product_candidate(uuid, text, bigint) from public, anon;
revoke all on function public.update_active_list_item(uuid, text, integer, text, bigint, uuid) from public, anon;
revoke all on function public.reset_product_memory(bigint) from public, anon;
revoke all on function public.remove_learned_preference(text, text, text, bigint) from public, anon;
revoke all on function public.create_checkout_session(uuid[], jsonb, text) from public, anon;
revoke all on function public.confirm_checkout_payment(uuid, text, text, text) from public, anon;
revoke all on function public.learned_preferences_summary() from public, anon;
revoke all on function public.has_plus_entitlement() from public, anon;
grant execute on function public.confirm_selection(uuid, integer, text, bigint) to authenticated;
grant execute on function public.reject_product_candidate(uuid, text, bigint) to authenticated;
grant execute on function public.update_active_list_item(uuid, text, integer, text, bigint, uuid) to authenticated;
grant execute on function public.reset_product_memory(bigint) to authenticated;
grant execute on function public.remove_learned_preference(text, text, text, bigint) to authenticated;
grant execute on function public.create_checkout_session(uuid[], jsonb, text) to authenticated;
grant execute on function public.confirm_checkout_payment(uuid, text, text, text) to authenticated;
grant execute on function public.learned_preferences_summary() to authenticated;
grant execute on function public.has_plus_entitlement() to authenticated;

revoke all on all tables in schema private from public, anon, authenticated;
revoke all on all functions in schema private from public, anon, authenticated;
alter default privileges in schema private revoke all on tables from public, anon, authenticated;
alter default privileges in schema private revoke all on functions from public, anon, authenticated;
