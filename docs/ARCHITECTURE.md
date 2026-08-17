# Architecture

## Client

The iOS application uses SwiftUI, Observation, MVVM, and a single typed `AppRouter`. `DependencyContainer` selects protocol-backed implementations for development, staging, or production. Views own presentation only; feature models coordinate services and map domain state to simple loading, empty, success, offline, and failure states.

Supabase remains the remote source of truth. SwiftData caches the active list and an idempotent outbox so an accepted local selection is not lost when connectivity changes. Keychain stores authentication material. Search and checkout remain online-only because availability, price, fees, and payment must be revalidated.

## Server

Authenticated Edge Functions derive the user from the verified token. The iPhone never supplies an authoritative entitlement, preference profile, price, fee, order status, or delivery status. Privileged provider operations use server-only credentials and private database tables.

Database functions own multi-row invariants such as confirming a product selection, applying a behavioral signal, advancing the memory epoch, completing checkout, and claiming reminder jobs. Unique constraints and idempotency keys protect every externally retried operation.

## Provider boundaries

- `IntentParsingService` converts text to a versioned `NeedIntent` schema.
- `ProductProvider` searches, reads, and verifies catalogue products.
- `RetailOrderProvider` creates the retailer-facing order.
- `PaymentService` prepares and confirms physical-goods payment.
- `DeliveryProvider` quotes, creates, cancels, and normalizes delivery updates.
- `PushProvider` sends a notification job to a device.

Development mocks implement every boundary. Production adapters fail closed when configuration is missing.

## Behavioral memory

Selection events are the canonical behavioral journal; order history is never silently re-imported. Aggregates are category- and currency-aware. Explicit current constraints form a ranking tier that memory cannot cross. A capped memory modifier influences ordering inside an eligible tier, while a discovery slot preserves strong novel choices.

Removing or resetting memory advances an epoch. Pending behavioral writes from an older epoch are invalidated locally and rejected server-side, so they cannot repopulate erased preferences.

## Daily reminder

The active list has no midnight lifecycle. One server cron invokes a batched dispatcher every minute. The dispatcher computes local due dates from an IANA timezone, claims a logical occurrence once, creates per-device jobs, revalidates list and checkout state, and then invokes the push provider. The notification only carries a list identifier and route; the app always reloads current server state after a tap.
