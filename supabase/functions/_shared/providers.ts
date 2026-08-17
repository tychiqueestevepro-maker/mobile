import type { DeliveryState } from "./types.ts";

export interface PaymentRequest {
  checkoutId: string;
  idempotencyKey: string;
  amountCents: number;
  currency: string;
  paymentToken?: string;
  testOutcome?: "authorized" | "action_required" | "failed";
}

export interface PaymentResult {
  state: "authorized" | "action_required" | "failed";
  reference: string;
}

export interface PaymentProvider {
  confirm(request: PaymentRequest): Promise<PaymentResult>;
}

export class MockPaymentProvider implements PaymentProvider {
  async confirm(request: PaymentRequest): Promise<PaymentResult> {
    await Promise.resolve();
    return {
      state: request.testOutcome ?? "authorized",
      reference: `pay_mock_${request.checkoutId.replaceAll("-", "").slice(0, 20)}`,
    };
  }
}

export interface RetailOrderRequest {
  retailerOrderId: string;
  orderId: string;
  retailerId: string;
  idempotencyKey: string;
}

export interface RetailOrderResult {
  state: "confirmed" | "failed";
  reference: string;
  failureReason?: string;
}

export interface RetailOrderProvider {
  create(
    request: RetailOrderRequest,
    testOutcome?: "confirmed" | "failed",
  ): Promise<RetailOrderResult>;
}

export class MockRetailOrderProvider implements RetailOrderProvider {
  async create(
    request: RetailOrderRequest,
    testOutcome: "confirmed" | "failed" = "confirmed",
  ): Promise<RetailOrderResult> {
    await Promise.resolve();
    return {
      state: testOutcome,
      reference: `ret_mock_${request.retailerOrderId.replaceAll("-", "").slice(0, 20)}`,
      failureReason: testOutcome === "failed" ? "Retailer could not accept the order" : undefined,
    };
  }
}

export interface DeliveryQuoteRequest {
  orderId: string;
  addressId: string;
  idempotencyKey?: string;
}
export interface DeliveryQuote {
  quoteCents: number;
  etaMinutes: number;
  expiresAt: string;
}
export interface DeliveryCreation {
  reference: string;
  state: DeliveryState;
  etaMinutes: number;
}

export interface DeliveryProvider {
  quote(request: DeliveryQuoteRequest): Promise<DeliveryQuote>;
  create(
    request: DeliveryQuoteRequest,
    testOutcome?: "confirmed" | "failed",
  ): Promise<DeliveryCreation>;
  cancel(reference: string): Promise<void>;
}

export class MockDeliveryProvider implements DeliveryProvider {
  async quote(_request: DeliveryQuoteRequest): Promise<DeliveryQuote> {
    await Promise.resolve();
    return {
      quoteCents: 699,
      etaMinutes: 35,
      expiresAt: new Date(Date.now() + 15 * 60_000).toISOString(),
    };
  }
  async create(
    request: DeliveryQuoteRequest,
    testOutcome: "confirmed" | "failed" = "confirmed",
  ): Promise<DeliveryCreation> {
    await Promise.resolve();
    return {
      reference: `del_mock_${request.orderId.replaceAll("-", "").slice(0, 20)}`,
      state: testOutcome,
      etaMinutes: 35,
    };
  }
  async cancel(_reference: string): Promise<void> {
    await Promise.resolve();
  }
}

const DELIVERY_STATUS_MAP: Record<string, DeliveryState> = {
  pending: "pending",
  confirmed: "confirmed",
  courier_assigned: "courier_assigned",
  courier_heading_to_pickup: "courier_heading_to_pickup",
  picked_up: "picked_up",
  on_the_way: "on_the_way",
  arriving: "arriving",
  delivered: "delivered",
  cancelled: "cancelled",
  canceled: "cancelled",
  failed: "failed",
};

export function normalizeDeliveryState(providerState: string): DeliveryState | null {
  return DELIVERY_STATUS_MAP[providerState.toLowerCase()] ?? null;
}

export function paymentProvider(): PaymentProvider {
  // V1 deliberately supports the safe mock only. A production adapter can be
  // selected here without changing handlers or the mobile client contract.
  return new MockPaymentProvider();
}
export function retailOrderProvider(): RetailOrderProvider {
  return new MockRetailOrderProvider();
}
export function deliveryProvider(): DeliveryProvider {
  return new MockDeliveryProvider();
}
