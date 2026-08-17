# Needs V1 implementation plan

## Delivery goals

- Build an iPhone-first SwiftUI application targeting iOS 17 with a complete mock journey: onboarding, authentication, typed and spoken needs, three product candidates, a persistent current list, checkout, orders, delivery tracking, Plus, learned preferences, settings, and reminders.
- Keep all provider-specific behavior behind protocols. Development must run without commerce, payment, delivery, push, or model credentials.
- Back the production-shaped flows with Supabase migrations, Row Level Security, transactional database functions, Edge Functions, scheduled reminder dispatch, and provider adapters.
- Keep consumer-facing copy in English and free of infrastructure or model-provider names.

## Repository layout

- `ios/`: XcodeGen project specification, app sources, assets, StoreKit configuration, unit tests, and UI tests.
- `supabase/`: configuration, SQL migrations, seed catalogue, Edge Functions, shared server modules, and backend tests.
- `.github/workflows/`: backend checks and macOS/Xcode build and test jobs.
- `docs/`: setup, architecture, provider integration, security, and release checklists.

## Implementation sequence

1. Scaffold the deterministic XcodeGen project, app environments, design system, routing, models, service protocols, mock dependency container, CI, and public example configuration.
2. Add the complete Supabase schema, indexes, constraints, RLS policies, private schemas, transactional functions, seed data, and local development configuration.
3. Implement authentication, onboarding, address entry, Home, native speech capture, intent parsing, product search, candidate selection, the persistent current list, and offline cache/outbox behavior.
4. Implement behavioral memory for all accounts, enable its ranking effect only for Plus, and expose learned-preference removal and reset in Settings.
5. Implement the daily-list reminder as a core workflow: user preference and timezone, APNs device registration, one scheduled dispatcher, idempotent notification jobs, and safe checkout deep links.
6. Implement StoreKit 2 entitlements, deterministic cart optimization, checkout, PassKit architecture, mock payment, retailer order creation, mock delivery progression, tracking, and order history.
7. Add backend, Swift unit, integration, and UI tests; security and forbidden-copy checks; accessibility and offline/error-state polish; setup and release documentation.

## Key invariants

- Current request constraints and availability always outrank historical behavior.
- A selection is persisted to the active list and behavioral journal atomically and idempotently.
- Unselected cards are neutral; explicit rejection/replacement is negative; removal is weakly negative; completed purchase is additional positive evidence.
- Free accounts accumulate behavioral history, but only a server-derived Plus entitlement enables personalized ranking.
- Resetting learned preferences prevents queued stale events or retained order history from recreating the deleted memory.
- A current list never resets at midnight. Items leave only through purchase, removal, or explicit carry-forward handling.
- No empty-list reminder is sent. Reminder dispatch is list-specific, timezone-aware, retry-safe, and unique per list, device, and local date.
- Notification payloads and client-supplied prices are never authoritative; the app reloads and revalidates server state before checkout.
- Checkout, payment, retailer order, delivery creation, and webhooks are idempotent.

## Verification gates

- Backend: SQL migrations reset cleanly, RLS isolates two test users, Edge Function tests pass, and optimizer/reminder/idempotency fixtures pass.
- iOS: macOS CI generates the project and runs `xcodebuild` unit/UI tests on an iPhone simulator.
- Mock acceptance: trash bags plus toothpaste by voice, three candidates each, persistent list, Plus optimization, mock payment, mock delivery timeline, tracking, history, learned-preference reset, and reminder deep link.
- Production adapters remain fail-closed until their credentials are supplied; no secret is committed.

