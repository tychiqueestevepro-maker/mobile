export type NeedSource = "text" | "voice";

export interface IntentAttribute {
  name: string;
  value: string;
}

export interface NeedIntent {
  category: string;
  normalized_query: string;
  attributes: IntentAttribute[];
  quantity: number;
  confidence: number;
  brand: string | null;
  format: string | null;
  size_value: number | null;
  size_unit: string | null;
  max_price_cents: number | null;
  clarification: { question: string; options: string[] } | null;
}

export interface CatalogOffer {
  id: string;
  product_id: string;
  retailer_id: string;
  external_offer_id: string;
  price_cents: number;
  currency: string;
  available: boolean;
  inventory_count: number | null;
  retailers?: Retailer | Retailer[] | null;
}

export interface Retailer {
  id: string;
  name: string;
  service_fee_bps: number;
  delivery_fee_cents: number;
  free_delivery_threshold_cents: number | null;
}

export interface CatalogProduct {
  id: string;
  category: string;
  name: string;
  brand: string;
  description: string;
  format: string | null;
  size_value: number | null;
  size_unit: string | null;
  unit_count: number;
  attributes: Record<string, string>;
  keywords: string[];
  image_url: string | null;
  product_offers: CatalogOffer[];
}

export interface MemoryEntry {
  category: string;
  dimension: string;
  value_key: string;
  score: number;
  positive_count: number;
  negative_count: number;
  numeric_value?: number | null;
  currency?: string | null;
}

export type CandidateRole = "best_match" | "best_value" | "discovery";

export interface RankedCandidate {
  product: CatalogProduct;
  offer: CatalogOffer;
  intentScore: number;
  memoryAdjustment: number;
  valueScore: number;
  finalScore: number;
  role: CandidateRole;
  reason: string;
}

export interface OptimizationOffer extends CatalogOffer {
  retailer: Retailer;
}

export interface OptimizationLine {
  item_id: string;
  product_id: string;
  quantity: number;
  current_offer_id?: string;
  offers: OptimizationOffer[];
}

export interface CartStrategy {
  stores: number;
  products_total_cents: number;
  delivery_total_cents: number;
  service_fee_cents: number;
  total_cents: number;
  offer_overrides: Record<string, string>;
}

export type DeliveryState =
  | "pending"
  | "confirmed"
  | "courier_assigned"
  | "courier_heading_to_pickup"
  | "picked_up"
  | "on_the_way"
  | "arriving"
  | "delivered"
  | "cancelled"
  | "failed";
