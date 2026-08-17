# Provider integration

## Development

All providers are deterministic. The catalogue spans the product categories in the product brief and multiple fictional retailers. Mock delivery advances through confirmed, courier assigned, picked up, on the way, arriving, and delivered. Mock failures can be selected through development scenarios.

## Intent parsing

The server provider sends a strict JSON Schema to the Responses API and accepts only the validated structured payload. The model identifier is environment configuration. The request contains the need text and schema only; no behavioral profile is needed for parsing. Development uses a local rules-based parser.

## Commerce

Product catalogue/search and retailer ordering are separate boundaries. No future delivery provider is assumed to expose stores, inventory, product pricing, consumer checkout, or retailer purchasing.

## Payment

The server creates an authoritative quote before PassKit is presented. A future PSP adapter must process the Apple Pay token and return a stable payment identifier. No retailer order or delivery is created until payment confirmation succeeds.

## Delivery

Provider statuses are mapped to the internal delivery enum. Webhooks are authenticated and idempotent. An external adapter must never leak provider-specific states into the application.

## Push

The APNs adapter uses token authentication and per-job identifiers. Invalid device tokens are disabled; rate limits and transient errors are retried with bounded backoff. The mock adapter records payloads without network delivery.

