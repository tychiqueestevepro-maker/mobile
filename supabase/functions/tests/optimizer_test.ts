import { assertEquals } from "@std/assert";
import { optimizeCart } from "../_shared/optimizer.ts";
import type { OptimizationLine, OptimizationOffer, Retailer } from "../_shared/types.ts";

function retailer(id: string, delivery: number): Retailer {
  return {
    id,
    name: id,
    service_fee_bps: 0,
    delivery_fee_cents: delivery,
    free_delivery_threshold_cents: null,
  };
}

function offer(id: string, product: string, store: Retailer, price: number): OptimizationOffer {
  return {
    id,
    product_id: product,
    retailer_id: store.id,
    external_offer_id: id,
    price_cents: price,
    currency: "USD",
    available: true,
    inventory_count: 10,
    retailer: store,
  };
}

Deno.test("optimizer chooses 74 dollar bundled total over 80 dollar fragmented products", () => {
  const storeA = retailer("a", 700);
  const storeB = retailer("b", 600);
  const storeC = retailer("c", 600);
  const storeD = retailer("d", 600);
  const lines: OptimizationLine[] = [
    {
      item_id: "1",
      product_id: "p1",
      quantity: 1,
      offers: [offer("a1", "p1", storeA, 2200), offer("b1", "p1", storeB, 2000)],
    },
    {
      item_id: "2",
      product_id: "p2",
      quantity: 1,
      offers: [offer("a2", "p2", storeA, 2200), offer("c2", "p2", storeC, 2000)],
    },
    {
      item_id: "3",
      product_id: "p3",
      quantity: 1,
      offers: [offer("a3", "p3", storeA, 2300), offer("d3", "p3", storeD, 2200)],
    },
  ];
  const result = optimizeCart(lines);
  assertEquals(result.recommended.products_total_cents, 6700);
  assertEquals(result.recommended.delivery_total_cents, 700);
  assertEquals(result.recommended.total_cents, 7400);
  assertEquals(result.recommended.stores, 1);
  assertEquals(6200 + 1800, 8000);
});

Deno.test("optimizer tie-breaks equal totals by fewer retailers", () => {
  const a = retailer("a", 0);
  const b = retailer("b", 0);
  const lines: OptimizationLine[] = [
    {
      item_id: "1",
      product_id: "p1",
      quantity: 1,
      offers: [offer("a1", "p1", a, 1000), offer("b1", "p1", b, 1000)],
    },
    {
      item_id: "2",
      product_id: "p2",
      quantity: 1,
      offers: [offer("a2", "p2", a, 1000), offer("b2", "p2", b, 1000)],
    },
  ];
  assertEquals(optimizeCart(lines).recommended.stores, 1);
});
