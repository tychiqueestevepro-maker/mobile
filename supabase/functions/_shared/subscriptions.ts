import { Buffer } from "node:buffer";
import { Environment, SignedDataVerifier } from "@apple/app-store-server-library";
import { AppError } from "./http.ts";

export interface VerifiedSubscriptionTransaction {
  userId: string;
  productId: string;
  originalTransactionId: string;
  transactionId: string;
  state: "active" | "grace_period" | "expired" | "revoked" | "cancelled";
  environment: "sandbox" | "production" | "mock";
  purchasedAt: string | null;
  expiresAt: string | null;
  revokedAt: string | null;
  raw: Record<string, unknown>;
}

interface DecodedTransaction extends Record<string, unknown> {
  appAccountToken?: string;
  productId?: string;
  originalTransactionId?: string;
  transactionId?: string;
  purchaseDate?: number;
  expiresDate?: number;
  revocationDate?: number;
  environment?: string;
}

function rootCertificates(): Buffer[] {
  const raw = Deno.env.get("APPLE_ROOT_CA_CERTIFICATES_BASE64") ?? "[]";
  let encoded: string[];
  try {
    const parsed = JSON.parse(raw);
    encoded = Array.isArray(parsed) ? parsed : [];
  } catch {
    encoded = raw.split(",").map((value) => value.trim()).filter(Boolean);
  }
  return encoded.map((certificate) => Buffer.from(certificate, "base64"));
}

function verifier(): { verifier: SignedDataVerifier; configuredEnvironment: string } {
  const configuredEnvironment = (Deno.env.get("STOREKIT_ENVIRONMENT") ??
    (Deno.env.get("APP_ENVIRONMENT") === "development" ? "xcode" : "")).toLowerCase();
  const bundleId = Deno.env.get("APPLE_BUNDLE_ID") ?? "com.tychi.mobile.needs";
  const onlineChecks = (Deno.env.get("APPLE_ENABLE_ONLINE_CHECKS") ?? "true") === "true";
  if (configuredEnvironment === "xcode") {
    if (Deno.env.get("APP_ENVIRONMENT") !== "development") {
      throw new AppError(
        500,
        "subscription_configuration",
        "Subscription verification is not configured.",
      );
    }
    return {
      verifier: new SignedDataVerifier([], false, Environment.XCODE, bundleId),
      configuredEnvironment,
    };
  }
  const roots = rootCertificates();
  if (roots.length === 0) {
    throw new AppError(
      500,
      "subscription_configuration",
      "Subscription verification is not configured.",
    );
  }
  if (configuredEnvironment === "sandbox") {
    return {
      verifier: new SignedDataVerifier(roots, onlineChecks, Environment.SANDBOX, bundleId),
      configuredEnvironment,
    };
  }
  if (configuredEnvironment === "production") {
    const appAppleId = Number(Deno.env.get("APPLE_APP_ID"));
    if (!Number.isSafeInteger(appAppleId) || appAppleId <= 0) {
      throw new AppError(
        500,
        "subscription_configuration",
        "Subscription verification is not configured.",
      );
    }
    return {
      verifier: new SignedDataVerifier(
        roots,
        onlineChecks,
        Environment.PRODUCTION,
        bundleId,
        appAppleId,
      ),
      configuredEnvironment,
    };
  }
  throw new AppError(
    500,
    "subscription_configuration",
    "Subscription verification is not configured.",
  );
}

function iso(milliseconds?: number): string | null {
  return typeof milliseconds === "number" && Number.isFinite(milliseconds)
    ? new Date(milliseconds).toISOString()
    : null;
}

function normalizeTransaction(
  decoded: DecodedTransaction,
  configuredEnvironment: string,
  stateOverride?: VerifiedSubscriptionTransaction["state"],
): VerifiedSubscriptionTransaction {
  const userId = decoded.appAccountToken?.toLowerCase();
  const productId = decoded.productId;
  const originalTransactionId = decoded.originalTransactionId;
  const transactionId = decoded.transactionId;
  if (!userId || !productId || !originalTransactionId || !transactionId) {
    throw new AppError(
      401,
      "invalid_transaction",
      "The subscription transaction could not be verified.",
    );
  }
  if (productId !== "com.tychi.mobile.plus.monthly") {
    throw new AppError(400, "unsupported_product", "That membership product is not supported.");
  }
  const now = Date.now();
  const state = stateOverride ??
    (decoded.revocationDate
      ? "revoked"
      : decoded.expiresDate && decoded.expiresDate > now
      ? "active"
      : "expired");
  return {
    userId,
    productId,
    originalTransactionId,
    transactionId,
    state,
    environment: configuredEnvironment === "production"
      ? "production"
      : configuredEnvironment === "sandbox"
      ? "sandbox"
      : "mock",
    purchasedAt: iso(decoded.purchaseDate),
    expiresAt: iso(decoded.expiresDate),
    revokedAt: iso(decoded.revocationDate),
    raw: decoded,
  };
}

export async function verifySignedTransaction(
  signedTransactionInfo: string,
  expectedUserId: string,
  suppliedAppAccountToken: string,
): Promise<VerifiedSubscriptionTransaction> {
  if (suppliedAppAccountToken.toLowerCase() !== expectedUserId.toLowerCase()) {
    throw new AppError(403, "account_mismatch", "The subscription belongs to a different account.");
  }
  try {
    const configured = verifier();
    const decoded = await configured.verifier.verifyAndDecodeTransaction(
      signedTransactionInfo,
    ) as DecodedTransaction;
    const transaction = normalizeTransaction(decoded, configured.configuredEnvironment);
    if (
      transaction.userId !== expectedUserId.toLowerCase() ||
      transaction.userId !== suppliedAppAccountToken.toLowerCase()
    ) {
      throw new AppError(
        403,
        "account_mismatch",
        "The subscription belongs to a different account.",
      );
    }
    return transaction;
  } catch (error) {
    if (error instanceof AppError) throw error;
    console.error("Store transaction verification failed", error);
    throw new AppError(
      401,
      "invalid_transaction",
      "The subscription transaction could not be verified.",
    );
  }
}

export async function verifySignedNotification(signedPayload: string): Promise<{
  eventId: string;
  transaction: VerifiedSubscriptionTransaction;
}> {
  try {
    const configured = verifier();
    if (configured.configuredEnvironment === "xcode") {
      throw new AppError(
        400,
        "unsupported_environment",
        "Server notifications are unavailable in local testing.",
      );
    }
    const notification = await configured.verifier.verifyAndDecodeNotification(
      signedPayload,
    ) as unknown as {
      notificationUUID?: string;
      notificationType?: string;
      subtype?: string;
      data?: { signedTransactionInfo?: string };
    };
    if (!notification.notificationUUID || !notification.data?.signedTransactionInfo) {
      throw new AppError(400, "invalid_notification", "The notification could not be verified.");
    }
    const decoded = await configured.verifier.verifyAndDecodeTransaction(
      notification.data.signedTransactionInfo,
    ) as DecodedTransaction;
    const stateOverride = notification.subtype === "GRACE_PERIOD"
      ? "grace_period"
      : notification.notificationType === "REVOKE"
      ? "revoked"
      : notification.notificationType === "EXPIRED"
      ? "expired"
      : undefined;
    return {
      eventId: notification.notificationUUID,
      transaction: normalizeTransaction(decoded, configured.configuredEnvironment, stateOverride),
    };
  } catch (error) {
    if (error instanceof AppError) throw error;
    console.error("Store notification verification failed", error);
    throw new AppError(401, "invalid_notification", "The notification could not be verified.");
  }
}
