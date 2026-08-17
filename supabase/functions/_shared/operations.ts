import type { SupabaseClient } from "@supabase/supabase-js";
import {
  AppError,
  readJson,
  requireSecret,
  requireString,
  requireUser,
  requireUuid,
  serviceClient,
  unwrap,
} from "./http.ts";
import { optimizeCart } from "./optimizer.ts";
import { parseNeed } from "./parsing.ts";
import {
  deliveryProvider,
  normalizeDeliveryState,
  paymentProvider,
  retailOrderProvider,
} from "./providers.ts";
import { type PushJob, pushProvider } from "./push.ts";
import { rankProducts } from "./ranking.ts";
import {
  type VerifiedSubscriptionTransaction,
  verifySignedNotification,
  verifySignedTransaction,
} from "./subscriptions.ts";
import type {
  CatalogOffer,
  CatalogProduct,
  DeliveryState,
  MemoryEntry,
  NeedIntent,
  OptimizationLine,
  OptimizationOffer,
} from "./types.ts";

export type Operation =
  | "parse-need"
  | "search-products"
  | "confirm-selection"
  | "reject-candidate"
  | "preferences-summary"
  | "remove-preference"
  | "reset-product-memory"
  | "update-active-list"
  | "create-checkout"
  | "confirm-payment"
  | "register-push-device"
  | "update-notification-preferences"
  | "delete-account"
  | "optimize-cart"
  | "create-retail-order"
  | "delivery-quote"
  | "create-delivery"
  | "delivery-webhook"
  | "sync-subscription"
  | "app-store-webhook"
  | "dispatch-daily-reminders";

type JsonObject = Record<string, unknown>;

function record(value: unknown): JsonObject {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new AppError(400, "invalid_request", "The request is invalid.");
  }
  return value as JsonObject;
}

function integer(value: unknown, field: string, min: number, max: number): number {
  if (!Number.isInteger(value) || Number(value) < min || Number(value) > max) {
    throw new AppError(400, "invalid_request", `${field} is invalid.`);
  }
  return Number(value);
}

function stringArray(value: unknown, field: string, max = 100): string[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > max) {
    throw new AppError(400, "invalid_request", `${field} is invalid.`);
  }
  return value.map((item) => requireString(item, field, 128));
}

function firstRelation<T>(value: T | T[] | null | undefined): T | null {
  return Array.isArray(value) ? value[0] ?? null : value ?? null;
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function beginServerOperation(
  service: SupabaseClient,
  userId: string,
  operation: string,
  idempotencyKey: string,
  input: unknown,
): Promise<{ started: boolean; status: "processing" | "completed"; response?: unknown }> {
  return unwrap(
    await service.rpc("begin_server_operation", {
      p_user_id: userId,
      p_operation: operation,
      p_idempotency_key: idempotencyKey,
      p_request_hash: await sha256(JSON.stringify(input)),
    }),
    "The operation could not be started.",
  ) as { started: boolean; status: "processing" | "completed"; response?: unknown };
}

async function completeServerOperation(
  service: SupabaseClient,
  userId: string,
  operation: string,
  idempotencyKey: string,
  response: unknown,
  succeeded = true,
): Promise<void> {
  const result = await service.rpc("complete_server_operation", {
    p_user_id: userId,
    p_operation: operation,
    p_idempotency_key: idempotencyKey,
    p_response: response,
    p_succeeded: succeeded,
  });
  if (result.error) {
    throw new AppError(500, "operation_failed", "The operation could not be completed.");
  }
}

async function parseNeedOperation(request: Request): Promise<unknown> {
  const context = await requireUser(request);
  const body = record(await readJson(request));
  const text = requireString(body.text, "text", 1000);
  const source = body.source === "voice" ? "voice" : "text";
  const intent = await parseNeed(text);
  const inserted = unwrap(
    await context.serviceClient.from("needs").insert({
      user_id: context.user.id,
      raw_input: text,
      source,
      parsed_intent: intent,
    }).select("id, created_at").single(),
    "We couldn't save that request.",
  );
  if (intent.attributes.length > 0) {
    const attributes = intent.attributes.map((item) => ({
      need_id: inserted.id,
      user_id: context.user.id,
      attribute_key: item.name.toLowerCase(),
      attribute_value: item.value,
    }));
    unwrap(
      await context.serviceClient.from("need_attributes").insert(attributes).select("id"),
      "We couldn't save that request.",
    );
  }
  return { need_id: inserted.id, created_at: inserted.created_at, intent };
}

async function searchProductsOperation(request: Request): Promise<unknown> {
  const context = await requireUser(request);
  const body = record(await readJson(request));
  const needId = requireUuid(body.need_id, "need_id");
  const need = unwrap(
    await context.serviceClient.from("needs")
      .select("id, user_id, parsed_intent").eq("id", needId).eq("user_id", context.user.id)
      .single(),
    "We couldn't find that request.",
  );
  const intent = need.parsed_intent as NeedIntent;
  const products = unwrap(
    await context.serviceClient.from("products").select(
      "id,category,name,brand,description,format,size_value,size_unit,unit_count,attributes,keywords,image_url,product_offers(id,product_id,retailer_id,external_offer_id,price_cents,currency,available,inventory_count,retailers(id,name,service_fee_bps,delivery_fee_cents,free_delivery_threshold_cents))",
    ).eq("active", true),
    "We couldn't find products right now.",
  ) as unknown as CatalogProduct[];
  const profile = unwrap(
    await context.serviceClient.from("profiles")
      .select("subscription_tier, plus_expires_at, memory_epoch").eq("user_id", context.user.id)
      .single(),
    "We couldn't load your preferences.",
  );
  const hasPlus = profile.subscription_tier === "plus" &&
    (!profile.plus_expires_at || new Date(profile.plus_expires_at).getTime() > Date.now());
  const memoryResult = await context.serviceClient.rpc("memory_entries_for_ranking", {
    p_user_id: context.user.id,
  });
  const memory = unwrap(memoryResult, "We couldn't load your preferences.") as MemoryEntry[];
  const ranked = rankProducts(products, intent, memory, hasPlus);
  if (ranked.length === 0) {
    throw new AppError(404, "no_products", "We couldn't find a good match right now.");
  }

  const { error: deleteError } = await context.serviceClient.from("product_candidates")
    .delete().eq("need_id", needId).eq("user_id", context.user.id);
  if (deleteError) {
    throw new AppError(400, "operation_failed", "We couldn't refresh these products.");
  }
  const rows = ranked.map((candidate, index) => ({
    user_id: context.user.id,
    need_id: needId,
    product_id: candidate.product.id,
    offer_id: candidate.offer.id,
    retailer_id: candidate.offer.retailer_id,
    category: candidate.product.category,
    name: candidate.product.name,
    brand: candidate.product.brand,
    format: candidate.product.format,
    size_value: candidate.product.size_value,
    size_unit: candidate.product.size_unit,
    unit_count: candidate.product.unit_count,
    attributes: candidate.product.attributes,
    price_cents: candidate.offer.price_cents,
    currency: candidate.offer.currency,
    available: candidate.offer.available,
    intent_score: candidate.intentScore,
    memory_adjustment: candidate.memoryAdjustment,
    value_score: candidate.valueScore,
    final_score: candidate.finalScore,
    result_role: candidate.role,
    rank: index + 1,
    reason: candidate.reason,
  }));
  const candidates = unwrap(
    await context.serviceClient.from("product_candidates").insert(rows)
      .select(
        "id,product_id,offer_id,retailer_id,category,name,brand,format,size_value,size_unit,unit_count,attributes,price_cents,currency,available,intent_score,memory_adjustment,value_score,final_score,result_role,rank,reason",
      ),
    "We couldn't prepare those products.",
  ) as Array<JsonObject>;
  const retailerNames = new Map<string, string>();
  for (const product of products) {
    for (const offer of product.product_offers ?? []) {
      const retailer = firstRelation(offer.retailers);
      if (retailer) retailerNames.set(offer.retailer_id, retailer.name);
    }
  }
  return {
    need_id: needId,
    memory_epoch: profile.memory_epoch,
    preferred_ranking_applied: hasPlus,
    candidates: candidates.map((candidate) => ({
      ...candidate,
      retailer_name: retailerNames.get(String(candidate.retailer_id)) ?? "Local retailer",
      image_url: products.find((product) => product.id === candidate.product_id)?.image_url ?? null,
    })),
  };
}

async function confirmSelectionOperation(request: Request): Promise<unknown> {
  const context = await requireUser(request);
  const body = record(await readJson(request));
  return unwrap(
    await context.userClient.rpc("confirm_selection", {
      p_candidate_id: requireUuid(body.candidate_id, "candidate_id"),
      p_quantity: integer(body.quantity ?? 1, "quantity", 1, 99),
      p_idempotency_key: requireString(body.idempotency_key, "idempotency_key", 128),
      p_memory_epoch: integer(body.memory_epoch, "memory_epoch", 1, Number.MAX_SAFE_INTEGER),
    }),
    "We couldn't add that product.",
  );
}

async function rejectCandidateOperation(request: Request): Promise<unknown> {
  const context = await requireUser(request);
  const body = record(await readJson(request));
  return unwrap(
    await context.userClient.rpc("reject_product_candidate", {
      p_candidate_id: requireUuid(body.candidate_id, "candidate_id"),
      p_idempotency_key: requireString(body.idempotency_key, "idempotency_key", 128),
      p_memory_epoch: integer(body.memory_epoch, "memory_epoch", 1, Number.MAX_SAFE_INTEGER),
    }),
    "We couldn't update that preference.",
  );
}

async function preferencesSummaryOperation(request: Request): Promise<unknown> {
  const context = await requireUser(request);
  await readJson(request).catch(() => ({}));
  const profile = unwrap(
    await context.userClient.from("profiles").select("memory_epoch").single(),
    "We couldn't load your preferences.",
  );
  const entries = unwrap(
    await context.userClient.rpc("learned_preferences_summary"),
    "We couldn't load your preferences.",
  );
  return { memory_epoch: profile.memory_epoch, entries };
}

async function removePreferenceOperation(request: Request): Promise<unknown> {
  const context = await requireUser(request);
  const body = record(await readJson(request));
  return unwrap(
    await context.userClient.rpc("remove_learned_preference", {
      p_category: requireString(body.category, "category", 80),
      p_dimension: requireString(body.dimension, "dimension", 80),
      p_value_key: requireString(body.value_key, "value_key", 160),
      p_expected_epoch: integer(body.memory_epoch, "memory_epoch", 1, Number.MAX_SAFE_INTEGER),
    }),
    "We couldn't remove that preference.",
  );
}

async function resetMemoryOperation(request: Request): Promise<unknown> {
  const context = await requireUser(request);
  const body = record(await readJson(request));
  return unwrap(
    await context.userClient.rpc("reset_product_memory", {
      p_expected_epoch: integer(body.memory_epoch, "memory_epoch", 1, Number.MAX_SAFE_INTEGER),
    }),
    "We couldn't reset your learned preferences.",
  );
}

async function updateListOperation(request: Request): Promise<unknown> {
  const context = await requireUser(request);
  const body = record(await readJson(request));
  return unwrap(
    await context.userClient.rpc("update_active_list_item", {
      p_item_id: requireUuid(body.item_id, "item_id"),
      p_action: requireString(body.action, "action", 32),
      p_quantity: body.quantity === null || body.quantity === undefined
        ? null
        : integer(body.quantity, "quantity", 1, 99),
      p_idempotency_key: typeof body.idempotency_key === "string" ? body.idempotency_key : "",
      p_memory_epoch: integer(body.memory_epoch, "memory_epoch", 1, Number.MAX_SAFE_INTEGER),
      p_candidate_id: typeof body.candidate_id === "string"
        ? requireUuid(body.candidate_id, "candidate_id")
        : null,
    }),
    "We couldn't update your list.",
  );
}

async function buildOptimizationLines(
  service: SupabaseClient,
  userId: string,
  itemIds: string[],
): Promise<OptimizationLine[]> {
  const items = unwrap(
    await service.from("active_list_items")
      .select("id,product_id,quantity,offer_id").eq("user_id", userId).eq("status", "active").in(
        "id",
        itemIds,
      ),
    "We couldn't verify your list.",
  ) as Array<{ id: string; product_id: string; quantity: number; offer_id: string }>;
  if (items.length !== itemIds.length) {
    throw new AppError(404, "item_not_found", "One or more list items were not found.");
  }
  const productIds = [...new Set(items.map((item) => item.product_id))];
  const available = unwrap(
    await service.from("product_offers").select(
      "id,product_id,retailer_id,external_offer_id,price_cents,currency,available,inventory_count,retailers(id,name,service_fee_bps,delivery_fee_cents,free_delivery_threshold_cents)",
    ).in("product_id", productIds).eq("available", true),
    "We couldn't verify availability.",
  ) as unknown as Array<CatalogOffer>;
  return items.map((item) => ({
    item_id: item.id,
    product_id: item.product_id,
    quantity: item.quantity,
    current_offer_id: item.offer_id,
    offers: available.filter((offer) => offer.product_id === item.product_id).flatMap((offer) => {
      const retailer = firstRelation(offer.retailers);
      return retailer ? [{ ...offer, retailer } as OptimizationOffer] : [];
    }),
  }));
}

async function createCheckoutOperation(request: Request): Promise<unknown> {
  const context = await requireUser(request);
  const body = record(await readJson(request));
  const selectedItemIds = stringArray(body.selected_item_ids, "selected_item_ids", 50).map((id) =>
    requireUuid(id, "selected_item_ids")
  );
  selectedItemIds.sort();
  const entitlement = unwrap(
    await context.userClient.rpc("has_plus_entitlement"),
    "We couldn't verify your membership.",
  ) as boolean;
  let optimization: ReturnType<typeof optimizeCart> | null = null;
  let overrides: Record<string, string> = {};
  if (entitlement) {
    const lines = await buildOptimizationLines(
      context.serviceClient,
      context.user.id,
      selectedItemIds,
    );
    optimization = optimizeCart(lines, 50_000, 200);
    overrides = optimization.recommended.offer_overrides;
  }
  const checkout = unwrap(
    await context.userClient.rpc("create_checkout_session", {
      p_selected_item_ids: selectedItemIds,
      p_offer_overrides: overrides,
      p_idempotency_key: requireString(body.idempotency_key, "idempotency_key", 128),
    }),
    "We couldn't start checkout.",
  );
  return { checkout, optimization, optimized: entitlement };
}

async function processRetailerOrders(
  service: SupabaseClient,
  orderId: string,
  userId: string,
  testOutcome?: "confirmed" | "failed",
): Promise<{ succeeded: boolean; retailer_orders: unknown[] }> {
  const retailerOrders = unwrap(
    await service.from("retailer_orders")
      .select("id,order_id,retailer_id,state,external_reference").eq("order_id", orderId).eq(
        "user_id",
        userId,
      ),
    "We couldn't submit the order.",
  ) as Array<
    {
      id: string;
      order_id: string;
      retailer_id: string;
      state: string;
      external_reference: string | null;
    }
  >;
  const results: unknown[] = [];
  let succeeded = true;
  for (const retailerOrder of retailerOrders) {
    if (["confirmed", "preparing", "ready", "fulfilled"].includes(retailerOrder.state)) {
      results.push(retailerOrder);
      continue;
    }
    const operationKey = `retailer-order:${retailerOrder.id}`;
    const claim = await beginServerOperation(
      service,
      userId,
      "retailer_provider",
      operationKey,
      { orderId, retailerOrderId: retailerOrder.id, retailerId: retailerOrder.retailer_id },
    );
    if (!claim.started && claim.status === "processing") {
      throw new AppError(
        409,
        "operation_in_progress",
        "The retailer order is already being submitted.",
      );
    }
    if (!claim.started && claim.status === "completed") {
      const refreshed = unwrap(
        await service.from("retailer_orders").select("*").eq("id", retailerOrder.id).single(),
        "We couldn't submit the order.",
      );
      results.push(refreshed);
      if (refreshed.state === "failed") succeeded = false;
      continue;
    }
    const result = await retailOrderProvider().create({
      retailerOrderId: retailerOrder.id,
      orderId,
      retailerId: retailerOrder.retailer_id,
      idempotencyKey: operationKey,
    }, testOutcome);
    const state = result.state === "confirmed" ? "confirmed" : "failed";
    const updated = unwrap(
      await service.from("retailer_orders").update({
        state,
        external_reference: result.reference,
        failure_reason: result.failureReason ?? null,
        submitted_at: new Date().toISOString(),
      }).eq("id", retailerOrder.id).select("*").single(),
      "We couldn't submit the order.",
    );
    await completeServerOperation(
      service,
      userId,
      "retailer_provider",
      operationKey,
      result,
    );
    results.push(updated);
    if (state === "failed") succeeded = false;
  }
  await service.from("orders").update(
    succeeded ? { state: "retailer_confirmed", failure_reason: null } : {
      state: "partially_failed",
      failure_reason: "One or more retailers could not accept the order",
    },
  )
    .eq("id", orderId).eq("user_id", userId);
  return { succeeded, retailer_orders: results };
}

async function defaultAddressId(service: SupabaseClient, userId: string): Promise<string | null> {
  const preference = await service.from("user_preferences").select("default_address_id").eq(
    "user_id",
    userId,
  ).maybeSingle();
  if (preference.data?.default_address_id) {
    const owned = await service.from("addresses").select("id")
      .eq("id", preference.data.default_address_id).eq("user_id", userId).maybeSingle();
    if (owned.data?.id) return owned.data.id;
  }
  const address = await service.from("addresses").select("id").eq("user_id", userId)
    .order("is_default", { ascending: false }).order("created_at", { ascending: true }).limit(1)
    .maybeSingle();
  return address.data?.id ?? null;
}

const simulationSteps: Array<{ state: DeliveryState; delayMs: number }> = [
  { state: "courier_assigned", delayMs: 2_000 },
  { state: "picked_up", delayMs: 2_000 },
  { state: "on_the_way", delayMs: 3_000 },
  { state: "arriving", delayMs: 3_000 },
  { state: "delivered", delayMs: 3_000 },
];

async function simulateDelivery(
  service: SupabaseClient,
  deliveryId: string,
  orderId: string,
  userId: string,
): Promise<void> {
  for (const step of simulationSteps) {
    await new Promise((resolve) => setTimeout(resolve, step.delayMs));
    const occurredAt = new Date().toISOString();
    const { error } = await service.from("deliveries").update({
      state: step.state,
      delivered_at: undefined,
      courier_display_name: step.state === "courier_assigned" ? "Alex" : undefined,
    }).eq("id", deliveryId);
    if (error) {
      console.error("Mock delivery simulation stopped", error);
      return;
    }
    await service.from("delivery_events").insert({
      delivery_id: deliveryId,
      order_id: orderId,
      user_id: userId,
      state: step.state,
      external_event_id: `simulation:${deliveryId}:${step.state}`,
      occurred_at: occurredAt,
      metadata: { simulated: true },
    });
    await service.from("orders").update(
      step.state === "delivered"
        ? { state: "delivered", delivered_at: occurredAt }
        : { state: "in_delivery" },
    ).eq("id", orderId);
  }
}

function runInBackground(promise: Promise<void>): void {
  const runtime =
    (globalThis as unknown as { EdgeRuntime?: { waitUntil: (value: Promise<void>) => void } })
      .EdgeRuntime;
  if (runtime?.waitUntil) runtime.waitUntil(promise);
  else promise.catch((error) => console.error("Background task failed", error));
}

async function createDeliveryForOrder(
  service: SupabaseClient,
  orderId: string,
  userId: string,
  addressId?: string,
  testOutcome?: "confirmed" | "failed",
): Promise<unknown | null> {
  const existing = await service.from("deliveries").select("*").eq("order_id", orderId)
    .maybeSingle();
  if (existing.data) return existing.data;
  const resolvedAddress = addressId ?? await defaultAddressId(service, userId);
  if (!resolvedAddress) return null;
  const result = await deliveryProvider().create(
    { orderId, addressId: resolvedAddress },
    testOutcome,
  );
  const now = new Date();
  const delivery = unwrap(
    await service.from("deliveries").insert({
      order_id: orderId,
      user_id: userId,
      address_id: resolvedAddress,
      state: result.state,
      external_reference: result.reference,
      quote_cents: 699,
      eta_start: new Date(now.getTime() + Math.max(5, result.etaMinutes - 10) * 60_000)
        .toISOString(),
      eta_end: new Date(now.getTime() + (result.etaMinutes + 10) * 60_000).toISOString(),
      failure_reason: result.state === "failed" ? "Delivery could not be created" : null,
    }).select("*").single(),
    "We couldn't arrange delivery.",
  );
  await service.from("delivery_events").insert({
    delivery_id: delivery.id,
    order_id: orderId,
    user_id: userId,
    state: result.state,
    external_event_id: `create:${result.reference}`,
    metadata: { simulated: true },
  });
  if (result.state === "failed") {
    await service.from("orders").update({
      state: "partially_failed",
      failure_reason: "Delivery needs attention",
    }).eq("id", orderId);
  } else {
    runInBackground(simulateDelivery(service, delivery.id, orderId, userId));
  }
  return delivery;
}

async function confirmPaymentOperation(request: Request): Promise<unknown> {
  const context = await requireUser(request);
  const body = record(await readJson(request));
  const checkoutId = requireUuid(body.checkout_id, "checkout_id");
  const idempotencyKey = requireString(body.idempotency_key, "idempotency_key", 128);
  const checkout = unwrap(
    await context.serviceClient.from("checkout_sessions")
      .select("id,user_id,state,total_cents,currency").eq("id", checkoutId).eq(
        "user_id",
        context.user.id,
      ).single(),
    "We couldn't find that checkout.",
  );
  const outcome = ["authorized", "action_required", "failed"].includes(String(body.test_outcome))
    ? body.test_outcome as "authorized" | "action_required" | "failed"
    : undefined;
  const payment = await paymentProvider().confirm({
    checkoutId,
    amountCents: checkout.total_cents,
    currency: checkout.currency,
    paymentToken: typeof body.payment_token === "string" ? body.payment_token : undefined,
    testOutcome: outcome,
    idempotencyKey: idempotencyKey,
  });
  const confirmation = unwrap(
    await context.userClient.rpc("confirm_checkout_payment", {
      p_checkout_session_id: checkoutId,
      p_payment_reference: payment.reference,
      p_provider_state: payment.state,
      p_idempotency_key: idempotencyKey,
    }),
    "We couldn't confirm payment.",
  ) as JsonObject;
  if (confirmation.state !== "succeeded" || typeof confirmation.order_id !== "string") {
    return confirmation;
  }
  const retailerResult = await processRetailerOrders(
    context.serviceClient,
    confirmation.order_id,
    context.user.id,
    body.retailer_test_outcome === "failed" ? "failed" : undefined,
  );
  if (!retailerResult.succeeded) {
    return {
      ...confirmation,
      state: "action_required",
      payment_state: "captured",
      ...retailerResult,
    };
  }
  const delivery = await createDeliveryForOrder(
    context.serviceClient,
    confirmation.order_id,
    context.user.id,
    typeof body.address_id === "string" ? requireUuid(body.address_id, "address_id") : undefined,
    body.delivery_test_outcome === "failed" ? "failed" : undefined,
  );
  return { ...confirmation, retailer_orders: retailerResult.retailer_orders, delivery };
}

async function registerPushOperation(request: Request): Promise<unknown> {
  const context = await requireUser(request);
  const body = record(await readJson(request));
  const token = requireString(body.token, "token", 512);
  const environment = requireString(body.environment ?? "sandbox", "environment", 16);
  if (!["sandbox", "production", "mock"].includes(environment)) {
    throw new AppError(400, "invalid_request", "environment is invalid.");
  }
  if (environment !== "mock" && !/^[a-f0-9]{32,512}$/i.test(token)) {
    throw new AppError(400, "invalid_request", "token is invalid.");
  }
  const deviceId = unwrap(
    await context.serviceClient.rpc("register_push_device", {
      p_user_id: context.user.id,
      p_token: token,
      p_environment: environment,
      p_app_version: typeof body.app_version === "string" ? body.app_version : null,
      p_locale: typeof body.locale === "string" ? body.locale : null,
    }),
    "We couldn't register notifications.",
  );
  return { device_id: deviceId, active: true };
}

function validateTimezone(timezone: string): void {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: timezone }).format(new Date());
  } catch {
    throw new AppError(400, "invalid_request", "timezone is invalid.");
  }
}

async function updateNotificationPreferencesOperation(request: Request): Promise<unknown> {
  const context = await requireUser(request);
  const body = record(await readJson(request));
  const timezone = requireString(body.timezone, "timezone", 80);
  validateTimezone(timezone);
  const reminderTime = requireString(body.reminder_time, "reminder_time", 8);
  if (!/^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$/.test(reminderTime)) {
    throw new AppError(400, "invalid_request", "reminder_time is invalid.");
  }
  if (typeof body.daily_list_enabled !== "boolean") {
    throw new AppError(400, "invalid_request", "daily_list_enabled is invalid.");
  }
  return unwrap(
    await context.userClient.from("notification_preferences").upsert({
      user_id: context.user.id,
      daily_list_enabled: body.daily_list_enabled,
      reminder_time: reminderTime,
      timezone,
    }).select("*").single(),
    "We couldn't update notification settings.",
  );
}

async function deleteAccountOperation(request: Request): Promise<unknown> {
  const context = await requireUser(request);
  await readJson(request).catch(() => ({}));
  const { error } = await context.serviceClient.auth.admin.deleteUser(context.user.id, false);
  if (error) {
    console.error("Account deletion failed", error);
    throw new AppError(
      500,
      "account_deletion_failed",
      "We couldn't delete your account right now.",
    );
  }
  return { deleted: true };
}

async function optimizeCartOperation(request: Request): Promise<unknown> {
  requireSecret(request, "x-internal-secret", "INTERNAL_API_SECRET");
  const body = record(await readJson(request));
  if (!Array.isArray(body.lines)) throw new AppError(400, "invalid_request", "lines is required.");
  const discount = typeof body.service_fee_discount_bps === "number"
    ? Math.max(0, Math.min(5_000, Math.trunc(body.service_fee_discount_bps)))
    : 0;
  return optimizeCart(body.lines as OptimizationLine[], 50_000, discount);
}

async function createRetailOrderOperation(request: Request): Promise<unknown> {
  const context = requireSecret(request, "x-internal-secret", "INTERNAL_API_SECRET");
  const body = record(await readJson(request));
  const orderId = requireUuid(body.order_id, "order_id");
  const order = unwrap(
    await context.serviceClient.from("orders").select("id,user_id").eq("id", orderId).single(),
    "Order not found.",
  );
  return processRetailerOrders(
    context.serviceClient,
    orderId,
    order.user_id,
    body.test_outcome === "failed" ? "failed" : undefined,
  );
}

async function deliveryQuoteOperation(request: Request): Promise<unknown> {
  requireSecret(request, "x-internal-secret", "INTERNAL_API_SECRET");
  const body = record(await readJson(request));
  return deliveryProvider().quote({
    orderId: requireUuid(body.order_id, "order_id"),
    addressId: requireUuid(body.address_id, "address_id"),
  });
}

async function createDeliveryOperation(request: Request): Promise<unknown> {
  const context = requireSecret(request, "x-internal-secret", "INTERNAL_API_SECRET");
  const body = record(await readJson(request));
  const orderId = requireUuid(body.order_id, "order_id");
  const order = unwrap(
    await context.serviceClient.from("orders").select("id,user_id").eq("id", orderId).single(),
    "Order not found.",
  );
  const delivery = await createDeliveryForOrder(
    context.serviceClient,
    orderId,
    order.user_id,
    typeof body.address_id === "string" ? requireUuid(body.address_id, "address_id") : undefined,
    body.test_outcome === "failed" ? "failed" : undefined,
  );
  if (!delivery) throw new AppError(409, "address_required", "A delivery address is required.");
  return delivery;
}

async function deliveryWebhookOperation(request: Request): Promise<unknown> {
  const context = requireSecret(request, "x-webhook-secret", "DELIVERY_WEBHOOK_SECRET");
  const body = record(await readJson(request));
  const eventId = requireString(body.event_id, "event_id", 160);
  const externalReference = requireString(body.delivery_reference, "delivery_reference", 200);
  const state = normalizeDeliveryState(requireString(body.status, "status", 80));
  if (!state) throw new AppError(400, "invalid_status", "Delivery status is invalid.");
  const claimed = unwrap(
    await context.serviceClient.rpc("claim_webhook_event", {
      p_provider: "delivery",
      p_external_event_id: eventId,
      p_payload_hash: await sha256(JSON.stringify(body)),
    }),
    "Webhook could not be recorded.",
  ) as boolean;
  if (!claimed) return { duplicate: true };
  const delivery = unwrap(
    await context.serviceClient.from("deliveries")
      .select("id,order_id,user_id").eq("external_reference", externalReference).single(),
    "Delivery not found.",
  );
  const occurredAt = typeof body.occurred_at === "string"
    ? body.occurred_at
    : new Date().toISOString();
  unwrap(
    await context.serviceClient.from("deliveries").update({
      state,
      eta_start: typeof body.eta_start === "string" ? body.eta_start : undefined,
      eta_end: typeof body.eta_end === "string" ? body.eta_end : undefined,
      courier_display_name: typeof body.courier_display_name === "string"
        ? body.courier_display_name
        : undefined,
      courier_location: body.courier_location && typeof body.courier_location === "object"
        ? body.courier_location
        : undefined,
      failure_reason: state === "failed" ? "Delivery needs attention" : null,
    }).eq("id", delivery.id).select("id").single(),
    "Delivery could not be updated.",
  );
  await context.serviceClient.from("delivery_events").insert({
    delivery_id: delivery.id,
    order_id: delivery.order_id,
    user_id: delivery.user_id,
    state,
    external_event_id: eventId,
    occurred_at: occurredAt,
    metadata: body.metadata && typeof body.metadata === "object" ? body.metadata : {},
  });
  const orderUpdate = state === "delivered"
    ? { state: "delivered", delivered_at: occurredAt, failure_reason: null }
    : state === "failed" || state === "cancelled"
    ? { state: "partially_failed", failure_reason: "Delivery needs attention" }
    : ["courier_assigned", "courier_heading_to_pickup", "picked_up", "on_the_way", "arriving"]
        .includes(state)
    ? { state: "in_delivery" }
    : {};
  if (Object.keys(orderUpdate).length > 0) {
    await context.serviceClient.from("orders").update(orderUpdate).eq("id", delivery.order_id);
  }
  return { duplicate: false, delivery_id: delivery.id, state };
}

async function persistVerifiedSubscription(
  service: SupabaseClient,
  transaction: VerifiedSubscriptionTransaction,
): Promise<unknown> {
  const subscription = unwrap(
    await service.from("subscriptions").upsert({
      user_id: transaction.userId,
      product_id: transaction.productId,
      original_transaction_id: transaction.originalTransactionId,
      state: transaction.state,
      environment: transaction.environment,
      purchased_at: transaction.purchasedAt,
      expires_at: transaction.expiresAt,
      revoked_at: transaction.revokedAt,
      raw_status: transaction.raw,
    }, { onConflict: "original_transaction_id" }).select("*").single(),
    "Subscription could not be synchronized.",
  );
  const active = ["active", "grace_period"].includes(transaction.state) &&
    (!transaction.expiresAt || new Date(transaction.expiresAt).getTime() > Date.now());
  unwrap(
    await service.from("profiles").update({
      subscription_tier: active ? "plus" : "free",
      plus_expires_at: transaction.expiresAt,
    }).eq("user_id", transaction.userId).select("user_id").single(),
    "Subscription could not be synchronized.",
  );
  return subscription;
}

async function syncSubscriptionOperation(request: Request): Promise<unknown> {
  const context = await requireUser(request);
  const body = record(await readJson(request));
  const signedTransactionInfo = requireString(
    body.signed_transaction_info,
    "signed_transaction_info",
    64_000,
  );
  const appAccountToken = requireUuid(body.app_account_token, "app_account_token");
  const transaction = await verifySignedTransaction(
    signedTransactionInfo,
    context.user.id,
    appAccountToken,
  );
  return persistVerifiedSubscription(context.serviceClient, transaction);
}

async function appStoreWebhookOperation(request: Request): Promise<unknown> {
  const body = record(await readJson(request));
  const signedPayload = requireString(
    body.signedPayload ?? body.signed_payload,
    "signedPayload",
    128_000,
  );
  const verified = await verifySignedNotification(signedPayload);
  const service = serviceClient();
  const claimed = unwrap(
    await service.rpc("claim_webhook_event", {
      p_provider: "app_store",
      p_external_event_id: verified.eventId,
      p_payload_hash: await sha256(signedPayload),
    }),
    "Webhook could not be recorded.",
  ) as boolean;
  if (!claimed) return { duplicate: true };
  const subscription = await persistVerifiedSubscription(service, verified.transaction);
  return { duplicate: false, subscription };
}

async function dispatchDailyRemindersOperation(request: Request): Promise<unknown> {
  const context = requireSecret(request, "x-cron-secret", "CRON_SECRET");
  await readJson(request).catch(() => ({}));
  const enqueued = unwrap(
    await context.serviceClient.rpc("enqueue_daily_list_reminders", {
      p_now: new Date().toISOString(),
    }),
    "Daily reminders could not be prepared.",
  ) as number;
  const jobs = unwrap(
    await context.serviceClient.rpc("claim_notification_jobs", { p_limit: 100 }),
    "Daily reminders could not be prepared.",
  ) as PushJob[];
  const provider = pushProvider();
  const results = await Promise.all(jobs.map(async (job) => {
    const result = await provider.send(job);
    const completion = await context.serviceClient.rpc("complete_notification_job", {
      p_job_id: job.job_id,
      p_outcome: result.outcome,
      p_provider_message_id: result.providerMessageId ?? null,
      p_error: result.error ?? null,
      p_invalidate_device: result.invalidateDevice ?? false,
    });
    if (completion.error) console.error("Notification completion failed", completion.error);
    return { job_id: job.job_id, outcome: result.outcome };
  }));
  return {
    occurrences_enqueued: enqueued,
    jobs_claimed: jobs.length,
    accepted: results.filter((result) => result.outcome === "accepted").length,
    retrying: results.filter((result) => result.outcome === "retry").length,
    failed: results.filter((result) => result.outcome === "failed").length,
  };
}

const handlers: Record<Operation, (request: Request) => Promise<unknown>> = {
  "parse-need": parseNeedOperation,
  "search-products": searchProductsOperation,
  "confirm-selection": confirmSelectionOperation,
  "reject-candidate": rejectCandidateOperation,
  "preferences-summary": preferencesSummaryOperation,
  "remove-preference": removePreferenceOperation,
  "reset-product-memory": resetMemoryOperation,
  "update-active-list": updateListOperation,
  "create-checkout": createCheckoutOperation,
  "confirm-payment": confirmPaymentOperation,
  "register-push-device": registerPushOperation,
  "update-notification-preferences": updateNotificationPreferencesOperation,
  "delete-account": deleteAccountOperation,
  "optimize-cart": optimizeCartOperation,
  "create-retail-order": createRetailOrderOperation,
  "delivery-quote": deliveryQuoteOperation,
  "create-delivery": createDeliveryOperation,
  "delivery-webhook": deliveryWebhookOperation,
  "sync-subscription": syncSubscriptionOperation,
  "app-store-webhook": appStoreWebhookOperation,
  "dispatch-daily-reminders": dispatchDailyRemindersOperation,
};

export function handleOperation(operation: Operation, request: Request): Promise<unknown> {
  return handlers[operation](request);
}
