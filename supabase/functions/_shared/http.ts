import { createClient, type SupabaseClient, type User } from "@supabase/supabase-js";

export const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers":
    "authorization, apikey, content-type, x-client-info, x-cron-secret, x-internal-secret, x-webhook-secret",
  "access-control-allow-methods": "POST, OPTIONS",
};

export class AppError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
    public readonly details?: unknown,
  ) {
    super(message);
  }
}

export interface UserContext {
  user: User;
  userClient: SupabaseClient;
  serviceClient: SupabaseClient;
  requestId: string;
}

export interface InternalContext {
  serviceClient: SupabaseClient;
  requestId: string;
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new AppError(500, "server_configuration", "Service is not configured.");
  return value;
}

export function serviceClient(): SupabaseClient {
  return createClient(requiredEnv("SUPABASE_URL"), requiredEnv("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export async function requireUser(request: Request): Promise<UserContext> {
  const authorization = request.headers.get("authorization");
  if (!authorization?.toLowerCase().startsWith("bearer ")) {
    throw new AppError(401, "unauthorized", "Please sign in and try again.");
  }
  const url = requiredEnv("SUPABASE_URL");
  const publishableKey = Deno.env.get("SUPABASE_ANON_KEY") ??
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  if (!publishableKey) {
    throw new AppError(500, "server_configuration", "Service is not configured.");
  }
  const userClient = createClient(url, publishableKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await userClient.auth.getUser();
  if (error || !data.user) throw new AppError(401, "unauthorized", "Please sign in and try again.");
  return {
    user: data.user,
    userClient,
    serviceClient: serviceClient(),
    requestId: crypto.randomUUID(),
  };
}

function constantTimeEqual(left: string, right: string): boolean {
  const encoder = new TextEncoder();
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  let mismatch = a.length ^ b.length;
  const length = Math.max(a.length, b.length);
  for (let i = 0; i < length; i += 1) {
    mismatch |= (a[i % Math.max(a.length, 1)] ?? 0) ^ (b[i % Math.max(b.length, 1)] ?? 0);
  }
  return mismatch === 0;
}

export function requireSecret(request: Request, header: string, envName: string): InternalContext {
  const received = request.headers.get(header) ?? "";
  const expected = requiredEnv(envName);
  if (!received || !constantTimeEqual(received, expected)) {
    throw new AppError(401, "unauthorized", "Request authentication failed.");
  }
  return { serviceClient: serviceClient(), requestId: crypto.randomUUID() };
}

export async function readJson<T>(request: Request): Promise<T> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    throw new AppError(415, "content_type", "A JSON request is required.");
  }
  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (declaredLength > 128_000) {
    throw new AppError(413, "request_too_large", "Request is too large.");
  }
  try {
    return await request.json() as T;
  } catch {
    throw new AppError(400, "invalid_json", "The request could not be read.");
  }
}

export function requireString(value: unknown, field: string, maxLength = 1000): string {
  if (typeof value !== "string" || value.trim().length === 0 || value.length > maxLength) {
    throw new AppError(400, "invalid_request", `${field} is required.`);
  }
  return value.trim();
}

export function requireUuid(value: unknown, field: string): string {
  const stringValue = requireString(value, field, 64);
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(stringValue)
  ) {
    throw new AppError(400, "invalid_request", `${field} is invalid.`);
  }
  return stringValue;
}

function jsonResponse(body: unknown, status: number, requestId: string): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-request-id": requestId,
    },
  });
}

export function serve(handler: (request: Request) => Promise<unknown>): void {
  Deno.serve(async (request) => {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }
    const fallbackRequestId = crypto.randomUUID();
    if (request.method !== "POST") {
      return jsonResponse(
        { error: { code: "method_not_allowed", message: "Method not allowed." } },
        405,
        fallbackRequestId,
      );
    }
    try {
      const data = await handler(request);
      return jsonResponse({ data }, 200, fallbackRequestId);
    } catch (error) {
      if (error instanceof AppError) {
        return jsonResponse(
          { error: { code: error.code, message: error.message, details: error.details } },
          error.status,
          fallbackRequestId,
        );
      }
      console.error("Unhandled Edge Function error", { requestId: fallbackRequestId, error });
      return jsonResponse(
        { error: { code: "internal_error", message: "Something went wrong. Please try again." } },
        500,
        fallbackRequestId,
      );
    }
  });
}

export function unwrap<T>(
  result: { data: T; error: { message: string; code?: string; details?: string } | null },
  message: string,
): NonNullable<T> {
  if (result.error || result.data === null) {
    console.error("Database operation failed", result.error);
    const status = result.error?.code === "P0002"
      ? 404
      : result.error?.code === "40001"
      ? 409
      : 400;
    throw new AppError(status, "operation_failed", message, result.error?.details);
  }
  return result.data as NonNullable<T>;
}
