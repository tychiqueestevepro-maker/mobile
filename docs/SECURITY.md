# Security model

- No service secret or provider credential is accepted by or returned to the iOS client.
- RLS is enabled on every exposed user-owned table and tested with two distinct users.
- Sensitive behavioral, device-token, provider, automation, and idempotency records live in a non-exposed schema.
- Edge Functions derive identity from a verified session and validate request bodies before database access.
- Prices, availability, fees, entitlements, list versions, and totals are recalculated server-side.
- Checkout, payment, retailer order, delivery creation, subscription notifications, and delivery webhooks are idempotent.
- Webhooks require provider authentication and store an external event identifier before applying a transition.
- Logs use correlation identifiers and avoid raw tokens, payment payloads, addresses, transcriptions, and learned-profile contents.
- Learned-preference reset deletes its journal and aggregate without using retained commerce history to recreate it.
- Account deletion removes user-owned and behavioral data through server-side cascading deletion; subscription management remains an Apple account operation.

Before production release, complete threat modelling, credential rotation, APNs and payment sandbox verification, privacy disclosures, data-retention review, and App Store privacy labels.

