import { assert, assertEquals } from "@std/assert";
import { rankProducts } from "../_shared/ranking.ts";
import type { CatalogProduct, MemoryEntry, NeedIntent } from "../_shared/types.ts";

function product(
  id: string,
  brand: string,
  strength: string,
  color: string,
  price: number,
): CatalogProduct {
  return {
    id,
    category: "trash_bags",
    name: `${strength} ${color} trash bags`,
    brand,
    description: `${strength} bags`,
    format: "drawstring",
    size_value: 13,
    size_unit: "gal",
    unit_count: 30,
    attributes: { strength, color },
    keywords: ["trash bags", strength, color],
    image_url: null,
    product_offers: [{
      id: `${id}-offer`,
      product_id: id,
      retailer_id: "store",
      external_offer_id: id,
      price_cents: price,
      currency: "USD",
      available: true,
      inventory_count: 10,
    }],
  };
}

const intent: NeedIntent = {
  category: "trash_bags",
  normalized_query: "strong black trash bags",
  attributes: [{ name: "strength", value: "heavy-duty" }, { name: "color", value: "black" }],
  quantity: 1,
  confidence: 0.95,
  brand: null,
  format: null,
  size_value: null,
  size_unit: null,
  max_price_cents: null,
  clarification: null,
};

Deno.test("current intent outranks a historical favorite and results remain capped at three", () => {
  const products = [
    product("exact", "NewBrand", "heavy-duty", "black", 1300),
    product("favorite", "OldFavorite", "standard", "black", 1100),
    product("value", "ValueBrand", "heavy-duty", "black", 1000),
    product("white", "OtherBrand", "heavy-duty", "white", 900),
  ];
  const memory: MemoryEntry[] = [{
    category: "trash_bags",
    dimension: "brand",
    value_key: "oldfavorite",
    score: 4,
    positive_count: 12,
    negative_count: 0,
  }];
  const ranked = rankProducts(products, intent, memory, true);
  assert(ranked.length <= 3);
  assert(ranked[0].product.id !== "favorite");
  assertEquals(ranked[0].role, "best_match");
  assert(ranked.some((candidate) => candidate.role === "discovery"));
});

Deno.test("free ranking records no memory adjustment", () => {
  const ranked = rankProducts(
    [
      product("one", "OldFavorite", "heavy-duty", "black", 1200),
      product("two", "NewBrand", "heavy-duty", "black", 1000),
    ],
    intent,
    [{
      category: "trash_bags",
      dimension: "brand",
      value_key: "oldfavorite",
      score: 4,
      positive_count: 8,
      negative_count: 0,
    }],
    false,
  );
  assertEquals(ranked.every((candidate) => candidate.memoryAdjustment === 0), true);
});
