# Needs

Needs is an iPhone-first SwiftUI application that turns a short request into three useful product choices, keeps selected products in one persistent current list, and supports checkout and delivery through replaceable providers.

The repository is production-shaped but credential-independent. The `development` environment uses deterministic mocks for authentication, product search, payment, retailer ordering, delivery, notifications, and intent parsing. Provider credentials are required only when enabling staging or production adapters.

## What is included

- Native SwiftUI application targeting iOS 17 with onboarding, Home, Orders, Settings, voice input, product candidates, checkout, tracking, Plus, and learned-preference controls.
- Persistent behavioral product memory. Free and Plus users generate signals; only Plus ranking consumes the learned profile. Current intent always wins.
- A persistent current list with a backend-scheduled daily reminder that never sends for an empty or already-ordered list.
- Supabase migrations, RLS, seeds, transactional operations, Edge Functions, mock providers, and scheduled reminder infrastructure.
- StoreKit 2 subscription support, PassKit architecture for physical-goods checkout, and complete mock commerce and delivery flows.

## Repository

- [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) records implementation order and invariants.
- `ios/` contains the XcodeGen project and application.
- `supabase/` contains database and server code.
- `docs/` contains setup, architecture, security, and provider notes.

## Quick start

1. Install Xcode 26.6+, XcodeGen, Docker, Node.js, Deno, and the Supabase CLI.
2. For a connected build, set `NEEDS_ENVIRONMENT`, `NEEDS_BACKEND_URL`, `NEEDS_PUBLISHABLE_KEY`, and optionally `NEEDS_MERCHANT_IDENTIFIER` in the scheme or matching public Info.plist values. `Configuration.example.swift` documents the allowed public shape; development mocks need no credentials.
3. Run `supabase start` and `supabase db reset` from the repository root for the local backend.
4. Run `xcodegen generate --spec ios/project.yml`.
5. Open `ios/Needs.xcodeproj` and run the `Needs` scheme.

The current Codex workspace is Windows-based, so iOS compilation and simulator validation are performed by the macOS CI workflow.

## Credentials

Never commit private keys. OpenAI, APNs, App Store Server, payment, retailer, and delivery secrets belong in Supabase Edge Function secrets. Apple Pay additionally needs a Merchant ID and a payment processor before real charges can be processed. See `docs/SETUP.md`.
