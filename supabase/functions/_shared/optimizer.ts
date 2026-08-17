import { AppError } from "./http.ts";
import type { CartStrategy, OptimizationLine, OptimizationOffer } from "./types.ts";

function evaluate(
  assignments: Array<{ line: OptimizationLine; offer: OptimizationOffer }>,
  serviceFeeDiscountBps: number,
): CartStrategy {
  const retailerTotals = new Map<string, { subtotal: number; offer: OptimizationOffer }>();
  const overrides: Record<string, string> = {};
  for (const { line, offer } of assignments) {
    overrides[line.item_id] = offer.id;
    const existing = retailerTotals.get(offer.retailer_id) ?? { subtotal: 0, offer };
    existing.subtotal += offer.price_cents * line.quantity;
    retailerTotals.set(offer.retailer_id, existing);
  }
  let products = 0;
  let delivery = 0;
  let service = 0;
  for (const { subtotal, offer } of retailerTotals.values()) {
    products += subtotal;
    service += Math.ceil(
      subtotal * Math.max(0, offer.retailer.service_fee_bps - serviceFeeDiscountBps) / 10_000,
    );
    delivery += offer.retailer.free_delivery_threshold_cents !== null &&
        subtotal >= offer.retailer.free_delivery_threshold_cents
      ? 0
      : offer.retailer.delivery_fee_cents;
  }
  return {
    stores: retailerTotals.size,
    products_total_cents: products,
    delivery_total_cents: delivery,
    service_fee_cents: service,
    total_cents: products + delivery + service,
    offer_overrides: overrides,
  };
}

export function optimizeCart(
  lines: OptimizationLine[],
  maxCombinations = 50_000,
  serviceFeeDiscountBps = 0,
): { recommended: CartStrategy; alternatives: CartStrategy[] } {
  if (lines.length === 0) throw new AppError(400, "empty_cart", "Your list is empty.");
  const normalized = lines.map((line) => ({
    ...line,
    offers: line.offers.filter((offer) =>
      offer.available && (offer.inventory_count === null || offer.inventory_count >= line.quantity)
    ),
  }));
  if (normalized.some((line) => line.offers.length === 0)) {
    throw new AppError(409, "unavailable_product", "One or more products are no longer available.");
  }
  const combinationCount = normalized.reduce((total, line) => total * line.offers.length, 1);
  if (combinationCount > maxCombinations) {
    for (const line of normalized) {
      line.offers = [...line.offers].sort((a, b) => a.price_cents - b.price_cents).slice(0, 4);
    }
  }
  const strategies = new Map<string, CartStrategy>();
  const walk = (
    index: number,
    assignments: Array<{ line: OptimizationLine; offer: OptimizationOffer }>,
  ) => {
    if (index === normalized.length) {
      const strategy = evaluate(assignments, Math.max(0, serviceFeeDiscountBps));
      const key = Object.entries(strategy.offer_overrides).sort().map(([item, offer]) =>
        `${item}:${offer}`
      ).join("|");
      strategies.set(key, strategy);
      return;
    }
    for (const offer of normalized[index].offers) {
      walk(index + 1, [...assignments, { line: normalized[index], offer }]);
      if (strategies.size >= maxCombinations) return;
    }
  };
  walk(0, []);
  const sorted = [...strategies.values()].sort((a, b) =>
    a.total_cents - b.total_cents || a.stores - b.stores ||
    JSON.stringify(a.offer_overrides).localeCompare(JSON.stringify(b.offer_overrides))
  );
  if (!sorted[0]) {
    throw new AppError(409, "unavailable_product", "No checkout combination is available.");
  }
  return { recommended: sorted[0], alternatives: sorted.slice(1, 4) };
}
