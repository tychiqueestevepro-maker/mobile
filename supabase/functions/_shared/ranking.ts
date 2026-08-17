import type {
  CatalogOffer,
  CatalogProduct,
  MemoryEntry,
  NeedIntent,
  RankedCandidate,
} from "./types.ts";

const normalize = (value: unknown): string => String(value ?? "").toLowerCase().trim();
const tokens = (value: string): string[] =>
  normalize(value).split(/[^a-z0-9]+/).filter((token) => token.length > 1);
const clamp = (value: number, min: number, max: number): number =>
  Math.max(min, Math.min(max, value));

function offers(product: CatalogProduct): CatalogOffer[] {
  return (product.product_offers ?? []).filter((offer) =>
    offer.available && (offer.inventory_count ?? 1) > 0
  );
}

function intentAttributes(intent: NeedIntent): Record<string, string> {
  return Object.fromEntries(
    intent.attributes.map((entry) => [normalize(entry.name), normalize(entry.value)]),
  );
}

function explicitMismatch(product: CatalogProduct, intent: NeedIntent): boolean {
  if (intent.category !== "other" && normalize(product.category) !== normalize(intent.category)) {
    return true;
  }
  if (intent.brand && normalize(product.brand) !== normalize(intent.brand)) return true;
  if (intent.format && normalize(product.format) !== normalize(intent.format)) return true;
  if (
    intent.max_price_cents !== null &&
    !offers(product).some((offer) => offer.price_cents <= intent.max_price_cents!)
  ) return true;
  const attrs = intentAttributes(intent);
  const hardKeys = new Set(["color", "material", "sensitivity", "battery_size"]);
  return Object.entries(attrs).some(([key, value]) => {
    const actual = normalize(product.attributes?.[key]);
    return hardKeys.has(key) && actual.length > 0 && actual !== value;
  });
}

function compatibility(product: CatalogProduct, intent: NeedIntent): number {
  if (explicitMismatch(product, intent) || offers(product).length === 0) return -1;
  let score = normalize(product.category) === normalize(intent.category) ? 0.58 : 0.2;
  const queryTokens = new Set(tokens(intent.normalized_query));
  const productTokens = new Set(tokens([
    product.name,
    product.brand,
    product.description,
    ...(product.keywords ?? []),
  ].join(" ")));
  const meaningful = [...queryTokens].filter((token) =>
    !["need", "some", "please", "with", "that", "get", "the", "for"].includes(token)
  );
  const matchedTokens = meaningful.filter((token) => productTokens.has(token)).length;
  score += meaningful.length > 0 ? 0.22 * (matchedTokens / meaningful.length) : 0.1;
  const attrs = intentAttributes(intent);
  const entries = Object.entries(attrs);
  if (entries.length > 0) {
    const matches = entries.filter(([key, value]) =>
      normalize(product.attributes?.[key]) === value
    ).length;
    score += 0.2 * (matches / entries.length);
  } else {
    score += 0.1;
  }
  if (intent.size_value !== null && intent.size_unit && product.size_value !== null) {
    if (normalize(product.size_unit) === normalize(intent.size_unit)) {
      const relativeDifference = Math.abs(product.size_value - intent.size_value) /
        Math.max(intent.size_value, 1);
      score += 0.1 * (1 - clamp(relativeDifference, 0, 1));
    }
  }
  return clamp(score, 0, 1);
}

function currentScoreTier(score: number): number {
  if (score >= 0.9) return 3;
  if (score >= 0.72) return 2;
  return 1;
}

function memoryAdjustment(
  product: CatalogProduct,
  offer: CatalogOffer,
  intentScore: number,
  memory: MemoryEntry[],
  plus: boolean,
): number {
  if (!plus || intentScore < 0.72) return 0;
  let raw = 0;
  for (
    const entry of memory.filter((item) => normalize(item.category) === normalize(product.category))
  ) {
    let matches = false;
    if (entry.dimension === "brand") {
      matches = normalize(product.brand) === normalize(entry.value_key);
    } else if (entry.dimension === "format") {
      matches = normalize(product.format) === normalize(entry.value_key);
    } else if (entry.dimension === "size") {
      matches =
        `${product.size_value}:${normalize(product.size_unit)}` === normalize(entry.value_key);
    } else if (entry.dimension.startsWith("attribute:")) {
      const key = entry.dimension.slice("attribute:".length);
      matches = normalize(product.attributes?.[key]) === normalize(entry.value_key);
    } else if (
      entry.dimension.startsWith("typical_price:") &&
      entry.positive_count >= 3 &&
      typeof entry.numeric_value === "number" &&
      entry.numeric_value > 0 &&
      normalize(entry.currency) === normalize(offer.currency)
    ) {
      const ratio = offer.price_cents / entry.numeric_value;
      raw += ratio <= 1.25 ? 0.015 : ratio > 1.5 ? -0.03 : 0;
    }
    if (matches) raw += clamp(Number(entry.score), -4, 4) * 0.018;
  }
  return clamp(raw, -0.1, 0.1);
}

function unitPrice(product: CatalogProduct, offer: CatalogOffer): number {
  const denominator = Math.max(
    1,
    Number(product.size_value ?? 1) * Math.max(1, product.unit_count),
  );
  return offer.price_cents / denominator;
}

export function rankProducts(
  products: CatalogProduct[],
  intent: NeedIntent,
  memory: MemoryEntry[],
  hasPreferredProductRanking: boolean,
): RankedCandidate[] {
  const scored = products.flatMap((product) => {
    const intentScore = compatibility(product, intent);
    if (intentScore < 0) return [];
    const availableOffers = offers(product)
      .filter((offer) =>
        intent.max_price_cents === null || offer.price_cents <= intent.max_price_cents
      )
      .sort((a, b) => a.price_cents - b.price_cents || a.retailer_id.localeCompare(b.retailer_id));
    if (availableOffers.length === 0) return [];
    const offer = availableOffers[0];
    const adjustment = memoryAdjustment(
      product,
      offer,
      intentScore,
      memory,
      hasPreferredProductRanking,
    );
    return [{ product, offer, intentScore, memoryAdjustment: adjustment }];
  });

  const unitPrices = scored.map(({ product, offer }) => unitPrice(product, offer));
  const low = Math.min(...unitPrices, 0);
  const high = Math.max(...unitPrices, 1);
  const withValues = scored.map((entry) => {
    const price = unitPrice(entry.product, entry.offer);
    const valueScore = high === low ? 1 : clamp(1 - (price - low) / (high - low), 0, 1);
    return {
      ...entry,
      valueScore,
      finalScore: clamp(entry.intentScore + entry.memoryAdjustment, 0, 1.1),
    };
  }).sort((a, b) =>
    currentScoreTier(b.intentScore) - currentScoreTier(a.intentScore) ||
    b.finalScore - a.finalScore ||
    a.offer.price_cents - b.offer.price_cents ||
    a.product.id.localeCompare(b.product.id)
  );
  if (withValues.length === 0) return [];

  const chosen: RankedCandidate[] = [];
  const best = withValues[0];
  chosen.push({ ...best, role: "best_match", reason: "Closest match to your request" });

  const strongFloor = Math.max(0.72, best.intentScore - 0.14);
  const bestValue =
    withValues.filter((entry) =>
      entry.product.id !== best.product.id && entry.intentScore >= strongFloor
    )
      .sort((a, b) =>
        b.valueScore - a.valueScore || b.finalScore - a.finalScore ||
        a.product.id.localeCompare(b.product.id)
      )[0];
  if (bestValue) {
    chosen.push({
      ...bestValue,
      role: "best_value",
      reason: "Strong match at a better unit value",
    });
  }

  const preferredBrand = memory.filter((entry) => entry.dimension === "brand" && entry.score > 0)
    .sort((a, b) => b.score - a.score)[0]?.value_key;
  const discovery =
    withValues.filter((entry) =>
      !chosen.some((choice) => choice.product.id === entry.product.id) &&
      entry.intentScore >= Math.max(0.65, best.intentScore - 0.22) &&
      (!preferredBrand || normalize(entry.product.brand) !== normalize(preferredBrand))
    ).sort((a, b) =>
      b.intentScore - a.intentScore || b.valueScore - a.valueScore ||
      a.product.id.localeCompare(b.product.id)
    )[0] ??
      withValues.find((entry) => !chosen.some((choice) => choice.product.id === entry.product.id));
  if (discovery) {
    chosen.push({
      ...discovery,
      role: "discovery",
      reason: "A relevant alternative worth discovering",
    });
  }

  return chosen.slice(0, 3);
}
