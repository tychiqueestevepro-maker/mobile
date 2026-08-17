# Release checklist

## Pre-requisites

- [ ] All provider environment variables listed in `SETUP.md` are configured in the target environment.
- [ ] Apple Developer team ID, signing certificate, and provisioning profile are active.
- [ ] APNs authentication key (`.p8`) is installed in the Supabase Edge Function environment.
- [ ] App Store Connect record exists with the correct bundle identifier.
- [ ] StoreKit product (`needs.plus.monthly`) is configured in App Store Connect.
- [ ] Apple Pay Merchant ID and payment processing certificate are active.
- [ ] Privacy Manifest (`PrivacyInfo.xcprivacy`) is up to date with required API declarations.

## Backend

- [ ] Run `supabase db reset` on a clean local instance — all migrations apply without errors.
- [ ] Run `supabase test db supabase/tests/database` — 19 assertions pass.
- [ ] Run `deno test --config supabase/functions/deno.json --allow-env supabase/functions/tests` — all function tests pass.
- [ ] Run `deno fmt --check supabase/functions` and `deno lint --config supabase/functions/deno.json supabase/functions` — no findings.
- [ ] Run `deno check --config supabase/functions/deno.json supabase/functions/_shared/*.ts supabase/functions/*/index.ts` — type-check passes.
- [ ] RLS tests confirm user A cannot read user B's lists, orders, or behavioral data.
- [ ] Staging Edge Functions respond to health checks and authenticated requests.
- [ ] `CRON_SECRET` is set and the `dispatch-daily-reminders` function responds only to authorized calls.

## iOS

- [ ] Run `xcodegen generate --spec ios/project.yml` — project generates without warnings.
- [ ] Run `xcodebuild -project ios/Needs.xcodeproj -scheme Needs -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' CODE_SIGNING_ALLOWED=NO test` — all unit and UI tests pass.
- [ ] Run `node scripts/check-consumer-copy.mjs` — no forbidden terms in consumer-facing code.
- [ ] StoreKit configuration file purchase flow succeeds in sandbox.
- [ ] Development build (mock providers) completes the full acceptance scenario: voiced request, three candidates, persistent list, checkout, delivery tracking, and order history.
- [ ] Staging build connects to real Supabase project and authenticates.
- [ ] Accessibility: enable VoiceOver on a device and navigate through onboarding, home, candidate selection, and checkout without unlabeled elements.
- [ ] Large Dynamic Type (Accessibility XL): confirm all screens remain usable and no text is clipped.

## App Store submission

- [ ] Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
- [ ] App Store privacy labels match data types declared in `PrivacyInfo.xcprivacy`.
- [ ] Age rating questionnaire completed (no objectionable content).
- [ ] App screenshots and preview video are current.
- [ ] Review notes explain mock provider behavior and provide a test account if required.
- [ ] Archive, validate, and upload with Xcode Organizer.

## Post-release

- [ ] Monitor Supabase dashboard for Edge Function errors and latency.
- [ ] Monitor App Store Connect crash reports for the first 48 hours.
- [ ] Confirm push notification delivery on a physical device.
- [ ] Verify daily reminder dispatch runs on schedule and deduplicates correctly.
- [ ] Confirm subscription purchase and entitlement propagation in production.
- [ ] Document rollback procedure: revert Edge Functions, keep database migrations forward-only.
