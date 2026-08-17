-- Needs V1 database. Public contains the mobile API surface. The private schema
-- is intentionally absent from PostgREST's exposed schemas.
create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create type public.subscription_tier as enum ('free', 'plus');
create type public.need_source as enum ('text', 'voice');
create type public.need_status as enum ('parsed', 'selected', 'dismissed');
create type public.list_status as enum ('open', 'checked_out', 'archived');
create type public.list_item_status as enum ('active', 'purchased', 'removed');
create type public.checkout_state as enum (
  'ready', 'processing', 'action_required', 'succeeded', 'failed', 'cancelled'
);
create type public.order_state as enum (
  'placed', 'retailer_confirmed', 'preparing', 'ready_for_pickup', 'in_delivery',
  'delivered', 'partially_failed', 'failed', 'cancelled'
);
create type public.retailer_order_state as enum (
  'pending', 'submitted', 'confirmed', 'preparing', 'ready', 'fulfilled', 'failed', 'cancelled'
);
create type public.delivery_state as enum (
  'pending', 'confirmed', 'courier_assigned', 'courier_heading_to_pickup',
  'picked_up', 'on_the_way', 'arriving', 'delivered', 'cancelled', 'failed'
);
create type public.payment_state as enum ('created', 'authorized', 'action_required', 'captured', 'voided', 'refunded', 'failed');
create type public.subscription_state as enum ('active', 'grace_period', 'expired', 'revoked', 'cancelled');

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  locale text not null default 'en-US',
  currency text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  timezone text not null default 'America/Los_Angeles',
  subscription_tier public.subscription_tier not null default 'free',
  plus_expires_at timestamptz,
  memory_epoch bigint not null default 1 check (memory_epoch > 0),
  onboarding_completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  label text not null default 'Home',
  recipient_name text not null,
  line1 text not null,
  line2 text,
  city text not null,
  region text not null,
  postal_code text not null,
  country_code text not null default 'US' check (country_code ~ '^[A-Z]{2}$'),
  latitude double precision,
  longitude double precision,
  delivery_instructions text,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index addresses_one_default_per_user
  on public.addresses(user_id) where is_default;
alter table public.addresses add constraint addresses_id_user_unique unique(id, user_id);

create table public.retailers (
  id text primary key,
  name text not null,
  service_fee_bps integer not null default 500 check (service_fee_bps between 0 and 5000),
  delivery_fee_cents integer not null default 699 check (delivery_fee_cents >= 0),
  free_delivery_threshold_cents integer check (free_delivery_threshold_cents >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.products (
  id text primary key,
  category text not null,
  name text not null,
  brand text not null,
  description text not null default '',
  format text,
  size_value numeric(12,3),
  size_unit text,
  unit_count integer not null default 1 check (unit_count > 0),
  attributes jsonb not null default '{}'::jsonb check (jsonb_typeof(attributes) = 'object'),
  keywords text[] not null default '{}',
  image_url text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index products_category_idx on public.products(category) where active;

create table public.product_offers (
  id uuid primary key default gen_random_uuid(),
  product_id text not null references public.products(id) on delete cascade,
  retailer_id text not null references public.retailers(id) on delete cascade,
  external_offer_id text not null,
  price_cents integer not null check (price_cents >= 0),
  currency text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  available boolean not null default true,
  inventory_count integer check (inventory_count is null or inventory_count >= 0),
  updated_at timestamptz not null default now(),
  unique (retailer_id, external_offer_id),
  unique (product_id, retailer_id)
);
create index product_offers_available_idx on public.product_offers(product_id, price_cents)
  where available;

create table public.needs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  raw_input text not null check (char_length(raw_input) between 1 and 1000),
  source public.need_source not null,
  parsed_intent jsonb not null check (jsonb_typeof(parsed_intent) = 'object'),
  status public.need_status not null default 'parsed',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index needs_user_created_idx on public.needs(user_id, created_at desc);

create table public.product_candidates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  need_id uuid not null references public.needs(id) on delete cascade,
  product_id text not null references public.products(id),
  offer_id uuid not null references public.product_offers(id),
  retailer_id text not null references public.retailers(id),
  category text not null,
  name text not null,
  brand text not null,
  format text,
  size_value numeric(12,3),
  size_unit text,
  unit_count integer not null,
  attributes jsonb not null default '{}'::jsonb,
  price_cents integer not null check (price_cents >= 0),
  currency text not null,
  available boolean not null default true,
  intent_score numeric(7,6) not null check (intent_score between 0 and 1),
  memory_adjustment numeric(7,6) not null default 0 check (memory_adjustment between -0.1 and 0.1),
  value_score numeric(7,6) not null default 0 check (value_score between 0 and 1),
  final_score numeric(7,6) not null check (final_score between 0 and 1.1),
  result_role text not null check (result_role in ('best_match', 'best_value', 'discovery')),
  rank smallint not null check (rank between 1 and 3),
  reason text not null,
  created_at timestamptz not null default now(),
  unique (need_id, rank),
  unique (need_id, product_id)
);
create index candidates_user_need_idx on public.product_candidates(user_id, need_id, rank);

create table public.active_lists (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  status public.list_status not null default 'open',
  opened_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index active_lists_one_open_per_user
  on public.active_lists(user_id) where status = 'open';
create index active_lists_user_created_idx on public.active_lists(user_id, created_at desc);

create table public.active_list_items (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.active_lists(id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  need_id uuid references public.needs(id) on delete set null,
  candidate_id uuid references public.product_candidates(id) on delete set null,
  product_id text not null references public.products(id),
  offer_id uuid not null references public.product_offers(id),
  retailer_id text not null references public.retailers(id),
  product_snapshot jsonb not null check (jsonb_typeof(product_snapshot) = 'object'),
  quantity integer not null default 1 check (quantity between 1 and 99),
  status public.list_item_status not null default 'active',
  carry_forward boolean not null default false,
  purchased_at timestamptz,
  removed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index active_list_items_unique_active_product
  on public.active_list_items(list_id, product_id) where status = 'active';
create index active_list_items_list_status_idx on public.active_list_items(list_id, status);

create table public.notification_preferences (
  user_id uuid primary key references public.profiles(user_id) on delete cascade,
  daily_list_enabled boolean not null default true,
  reminder_time time not null default '17:00:00',
  timezone text not null default 'America/Los_Angeles',
  updated_at timestamptz not null default now()
);

create table public.user_preferences (
  user_id uuid primary key references public.profiles(user_id) on delete cascade,
  default_address_id uuid,
  allow_preference_learning boolean not null default true,
  measurement_system text not null default 'us' check (measurement_system in ('us', 'metric')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (default_address_id, user_id)
    references public.addresses(id, user_id) on delete set null (default_address_id)
);

create table public.need_attributes (
  id uuid primary key default gen_random_uuid(),
  need_id uuid not null references public.needs(id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  attribute_key text not null,
  attribute_value text not null,
  created_at timestamptz not null default now(),
  unique (need_id, attribute_key)
);

create table public.selected_products (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  need_id uuid references public.needs(id) on delete set null,
  candidate_id uuid references public.product_candidates(id) on delete set null,
  list_item_id uuid not null references public.active_list_items(id) on delete cascade,
  product_id text not null references public.products(id),
  quantity integer not null check (quantity between 1 and 99),
  selected_at timestamptz not null default now(),
  unique (user_id, candidate_id)
);

create table public.checkout_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  list_id uuid not null references public.active_lists(id),
  state public.checkout_state not null default 'ready',
  selected_item_ids uuid[] not null,
  pricing_snapshot jsonb not null check (jsonb_typeof(pricing_snapshot) = 'object'),
  subtotal_cents integer not null check (subtotal_cents >= 0),
  service_fee_cents integer not null check (service_fee_cents >= 0),
  delivery_fee_cents integer not null check (delivery_fee_cents >= 0),
  tax_cents integer not null default 0 check (tax_cents >= 0),
  total_cents integer generated always as
    (subtotal_cents + service_fee_cents + delivery_fee_cents + tax_cents) stored,
  currency text not null default 'USD',
  idempotency_key text not null,
  payment_reference text,
  failure_code text,
  expires_at timestamptz not null default (now() + interval '15 minutes'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, idempotency_key)
);
create index checkout_sessions_list_state_idx on public.checkout_sessions(list_id, state);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  list_id uuid not null references public.active_lists(id),
  checkout_session_id uuid not null unique references public.checkout_sessions(id),
  state public.order_state not null default 'placed',
  subtotal_cents integer not null,
  service_fee_cents integer not null,
  delivery_fee_cents integer not null,
  tax_cents integer not null,
  total_cents integer not null,
  currency text not null,
  failure_reason text,
  placed_at timestamptz not null default now(),
  delivered_at timestamptz,
  updated_at timestamptz not null default now()
);
create index orders_user_placed_idx on public.orders(user_id, placed_at desc);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  checkout_session_id uuid not null references public.checkout_sessions(id) on delete cascade,
  order_id uuid references public.orders(id) on delete set null,
  state public.payment_state not null default 'created',
  provider_reference text,
  amount_cents integer not null check (amount_cents >= 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  idempotency_key text not null,
  failure_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, idempotency_key),
  unique (checkout_session_id, provider_reference)
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  list_item_id uuid references public.active_list_items(id) on delete set null,
  product_id text not null,
  retailer_id text not null,
  product_snapshot jsonb not null,
  quantity integer not null check (quantity > 0),
  unit_price_cents integer not null check (unit_price_cents >= 0),
  created_at timestamptz not null default now()
);
create index order_items_order_idx on public.order_items(order_id);

create table public.retailer_orders (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  retailer_id text not null references public.retailers(id),
  state public.retailer_order_state not null default 'pending',
  external_reference text,
  subtotal_cents integer not null check (subtotal_cents >= 0),
  failure_reason text,
  submitted_at timestamptz,
  updated_at timestamptz not null default now(),
  unique(order_id, retailer_id)
);

create table public.deliveries (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  address_id uuid references public.addresses(id) on delete set null,
  state public.delivery_state not null default 'pending',
  external_reference text,
  quote_cents integer not null default 0 check (quote_cents >= 0),
  eta_start timestamptz,
  eta_end timestamptz,
  courier_display_name text,
  courier_location jsonb,
  failure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.delivery_events (
  id uuid primary key default gen_random_uuid(),
  delivery_id uuid not null references public.deliveries(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  state public.delivery_state not null,
  external_event_id text,
  occurred_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (delivery_id, external_event_id)
);
create index delivery_events_delivery_time_idx on public.delivery_events(delivery_id, occurred_at);

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  product_id text not null,
  original_transaction_id text not null unique,
  state public.subscription_state not null,
  environment text not null check (environment in ('sandbox', 'production', 'mock')),
  purchased_at timestamptz,
  expires_at timestamptz,
  revoked_at timestamptz,
  raw_status jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index subscriptions_user_state_idx on public.subscriptions(user_id, state, expires_at desc);

create table private.preference_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  memory_epoch bigint not null,
  category text not null,
  event_type text not null check (event_type in ('selection', 'purchase', 'rejection', 'replacement', 'removal')),
  weight numeric(6,3) not null check (weight in (1, -1, -0.25)),
  product_id text,
  candidate_id uuid,
  dimensions jsonb not null check (jsonb_typeof(dimensions) = 'object'),
  idempotency_key text not null,
  occurred_at timestamptz not null default now(),
  unique (user_id, event_type, idempotency_key)
);
create index preference_events_user_epoch_idx
  on private.preference_events(user_id, memory_epoch, occurred_at desc);

create table private.preference_profile_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  memory_epoch bigint not null,
  category text not null,
  dimension text not null,
  value_key text not null,
  score numeric(12,6) not null default 0,
  positive_count integer not null default 0,
  negative_count integer not null default 0,
  numeric_value numeric(14,4),
  currency text,
  last_event_at timestamptz not null default now(),
  unique (user_id, memory_epoch, category, dimension, value_key)
);
create index preference_profile_lookup_idx
  on private.preference_profile_entries(user_id, memory_epoch, category, dimension, score desc);

create table private.push_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  token text not null,
  platform text not null default 'ios' check (platform = 'ios'),
  environment text not null check (environment in ('sandbox', 'production', 'mock')),
  app_version text,
  locale text,
  active boolean not null default true,
  last_seen_at timestamptz not null default now(),
  invalidated_at timestamptz,
  created_at timestamptz not null default now(),
  unique (token, environment)
);
create index push_devices_active_user_idx on private.push_devices(user_id) where active;

create table private.notification_occurrences (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  list_id uuid not null references public.active_lists(id) on delete cascade,
  local_date date not null,
  kind text not null check (kind = 'daily_list'),
  scheduled_for timestamptz not null,
  created_at timestamptz not null default now(),
  unique (user_id, list_id, local_date, kind)
);

create table private.notification_jobs (
  id uuid primary key default gen_random_uuid(),
  occurrence_id uuid not null references private.notification_occurrences(id) on delete cascade,
  device_id uuid not null references private.push_devices(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'sending', 'accepted', 'retry', 'failed')),
  attempts integer not null default 0,
  available_at timestamptz not null default now(),
  claimed_at timestamptz,
  provider_message_id text,
  last_error text,
  updated_at timestamptz not null default now(),
  unique (occurrence_id, device_id)
);
create index notification_jobs_claim_idx
  on private.notification_jobs(status, available_at) where status in ('pending', 'retry');

create table private.idempotency_keys (
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  operation text not null,
  idempotency_key text not null,
  request_hash text not null,
  status text not null default 'processing' check (status in ('processing', 'completed', 'failed')),
  response jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, operation, idempotency_key)
);

create table private.provider_payloads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(user_id) on delete cascade,
  aggregate_type text not null,
  aggregate_id uuid not null,
  provider text not null,
  direction text not null check (direction in ('request', 'response', 'webhook')),
  payload jsonb not null,
  created_at timestamptz not null default now()
);

create table private.webhook_events (
  provider text not null,
  external_event_id text not null,
  payload_hash text not null,
  processed_at timestamptz not null default now(),
  response jsonb,
  primary key (provider, external_event_id)
);

comment on schema private is 'Server-only product memory, push credentials, provider payloads, and idempotency state.';
comment on column public.profiles.memory_epoch is 'Invalidates stale offline memory writes after any user removal/reset.';
comment on table public.active_lists is 'A persistent list; it is never reset at local midnight.';
