import { assertEquals } from "@std/assert";
import { MockPaymentProvider, normalizeDeliveryState } from "../_shared/providers.ts";

Deno.test("delivery provider states map only to normalized internal states", () => {
  assertEquals(normalizeDeliveryState("on_the_way"), "on_the_way");
  assertEquals(normalizeDeliveryState("canceled"), "cancelled");
  assertEquals(normalizeDeliveryState("provider_secret_status"), null);
});

Deno.test("mock payment reference and result are deterministic", async () => {
  const provider = new MockPaymentProvider();
  const first = await provider.confirm({
    checkoutId: "abc-def",
    checkoutId: "abc-def",
    amountCents: 1200,
    currency: "USD",
    idempotencyKey: "idem-key-1",
  });
  const second = await provider.confirm({
    checkoutId: "abc-def",
    checkoutId: "abc-def",
    amountCents: 1200,
    currency: "USD",
    idempotencyKey: "idem-key-2",
  });
  assertEquals(first, second);
  assertEquals(first.state, "authorized");
});
