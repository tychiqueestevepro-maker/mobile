# Setup

## Local backend

Requirements: Docker, Node.js, and the Supabase CLI.

```text
supabase start
supabase db reset
supabase functions serve --env-file supabase/functions/.env.local
```

Copy `supabase/.env.example` to the ignored `supabase/functions/.env.local` only when testing non-mock adapters. Local database URLs and keys are printed by `supabase status`.

## iOS

Requirements: macOS Tahoe 26.2+, Xcode 26.6+, and XcodeGen 2.45.4+.

```text
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/Needs.xcodeproj -scheme Needs -destination "platform=iOS Simulator,name=iPhone 16 Pro,OS=latest" test
```

The checked-in StoreKit configuration provides a local monthly Plus subscription. Its displayed price comes from StoreKit. It does not configure an App Store Connect product.

## Public client configuration

Only these values may be compiled into the application:

- Supabase project URL and publishable key;
- environment name;
- StoreKit product identifier;
- Apple Pay merchant identifier;
- callback/deep-link scheme.

Set `NEEDS_ENVIRONMENT`, `NEEDS_BACKEND_URL`, `NEEDS_PUBLISHABLE_KEY`, and optionally `NEEDS_MERCHANT_IDENTIFIER` in the Xcode scheme, or add the equivalent public Info.plist values documented by `PublicConfiguration.runtime()`. Staging and production fail closed when their public URL or publishable key is absent. Use the development environment for the credential-free mock application.

## Server secrets

Set these only in the relevant hosted environment:

- `OPENAI_API_KEY` and `OPENAI_MODEL`;
- `APNS_PRIVATE_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`, and `APNS_ENVIRONMENT`;
- App Store Server credentials;
- payment processor credentials;
- retailer and delivery provider credentials;
- `CRON_SECRET` and `INTERNAL_API_SECRET` for scheduled and internal functions.

The application remains fully testable with mocks when any of these are absent.

## Apple capabilities

Real Sign in with Apple, APNs, StoreKit sandbox, and Apple Pay require an Apple Developer team and signed entitlements. Apple Pay also requires a Merchant ID, payment-processing certificate, physical device, and processor sandbox. Do not substitute StoreKit for physical-goods payment.
