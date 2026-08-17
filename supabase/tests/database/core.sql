begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

select has_table('public', 'payments', 'payments table exists');
select has_table('public', 'subscriptions', 'subscriptions table exists');
select has_table('public', 'delivery_events', 'delivery events table exists');
select has_table('private', 'preference_events', 'private memory event table exists');
select has_table('private', 'notification_jobs', 'private notification job table exists');

insert into auth.users(
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('10000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'first@example.test', '', now(), '{}', '{}', now(), now()),
  ('10000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'second@example.test', '', now(), '{}', '{}', now(), now());

select is(
  (select count(*) from public.active_lists where user_id = '10000000-0000-4000-8000-000000000001' and status = 'open'),
  1::bigint,
  'signup creates exactly one persistent open list'
);

insert into public.retailers(id, name, service_fee_bps, delivery_fee_cents) values ('test-store', 'Test Store', 0, 0);
insert into public.products(id, category, name, brand, unit_count, attributes)
values ('test-product', 'trash_bags', 'Strong Black Bags', 'TestBrand', 30, '{"color":"black","strength":"heavy-duty"}');
insert into public.product_offers(id, product_id, retailer_id, external_offer_id, price_cents, currency)
values ('20000000-0000-4000-8000-000000000001', 'test-product', 'test-store', 'test-offer', 1000, 'USD');
insert into public.needs(id, user_id, raw_input, source, parsed_intent)
values ('30000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'bags', 'text', '{"category":"trash_bags"}');
insert into public.product_candidates(
  id, user_id, need_id, product_id, offer_id, retailer_id, category, name, brand,
  unit_count, attributes, price_cents, currency, intent_score, final_score,
  value_score, result_role, rank, reason
) values (
  '40000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
  '30000000-0000-4000-8000-000000000001', 'test-product',
  '20000000-0000-4000-8000-000000000001', 'test-store', 'trash_bags',
  'Strong Black Bags', 'TestBrand', 30, '{"color":"black","strength":"heavy-duty"}',
  1000, 'USD', 0.95, 0.95, 0.8, 'best_match', 1, 'Exact match'
);

select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
set local role authenticated;
select lives_ok(
  $$select public.confirm_selection('40000000-0000-4000-8000-000000000001', 1, 'select-once', 1)$$,
  'first selection succeeds'
);
select lives_ok(
  $$select public.confirm_selection('40000000-0000-4000-8000-000000000001', 1, 'select-once', 1)$$,
  'duplicate idempotency key returns the original selection'
);
reset role;

select is(
  (select count(*) from public.active_list_items where user_id = '10000000-0000-4000-8000-000000000001' and status = 'active'),
  1::bigint,
  'idempotent selection creates one item'
);
select is(
  (select quantity from public.active_list_items where user_id = '10000000-0000-4000-8000-000000000001' and status = 'active'),
  1,
  'idempotent replay does not increment quantity'
);
select is(
  (select count(*) from private.preference_events where user_id = '10000000-0000-4000-8000-000000000001'),
  1::bigint,
  'idempotent replay records one behavioral event'
);

set local role authenticated;
select lives_ok($$select public.reset_product_memory(1)$$, 'memory reset succeeds at current epoch');
select throws_ok(
  $$select public.reject_product_candidate('40000000-0000-4000-8000-000000000001', 'stale', 1)$$,
  '40001',
  'Stale memory epoch',
  'stale offline memory write is rejected'
);
reset role;
select is((select memory_epoch from public.profiles where user_id = '10000000-0000-4000-8000-000000000001'), 2::bigint, 'reset increments epoch');
select is((select count(*) from private.preference_events where user_id = '10000000-0000-4000-8000-000000000001'), 0::bigint, 'reset purges behavioral events');

update public.notification_preferences set timezone = 'UTC', reminder_time = '00:00', daily_list_enabled = true
where user_id = '10000000-0000-4000-8000-000000000001';
insert into private.push_devices(user_id, token, environment)
values ('10000000-0000-4000-8000-000000000001', 'mock-device-one', 'mock');
select is(
  public.enqueue_daily_list_reminders(date_trunc('day', now()) + interval '1 day 12 hours'),
  1,
  'non-empty open list enqueues one logical reminder'
);
select is(
  public.enqueue_daily_list_reminders(date_trunc('day', now()) + interval '1 day 12 hours'),
  0,
  'same list and local day reminder is deduplicated'
);
update public.notification_preferences set daily_list_enabled = false
where user_id = '10000000-0000-4000-8000-000000000001';
update public.notification_preferences set timezone = 'UTC', reminder_time = '00:00', daily_list_enabled = true
where user_id = '10000000-0000-4000-8000-000000000002';
insert into private.push_devices(user_id, token, environment)
values ('10000000-0000-4000-8000-000000000002', 'mock-device-two', 'mock');
select is(
  public.enqueue_daily_list_reminders(date_trunc('day', now()) + interval '1 day 12 hours'),
  0,
  'empty list never enqueues a reminder'
);

select throws_ok(
  $$insert into public.active_lists(user_id) values ('10000000-0000-4000-8000-000000000002')$$,
  '23505',
  null,
  'database enforces one open list per user'
);

select * from finish();
rollback;
