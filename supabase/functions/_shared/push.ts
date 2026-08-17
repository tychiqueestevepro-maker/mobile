export interface PushJob {
  job_id: string;
  token: string;
  environment: "sandbox" | "production" | "mock";
  deep_link: string;
  expiration_epoch: number;
  attempts: number;
}

export interface PushResult {
  outcome: "accepted" | "retry" | "failed";
  providerMessageId?: string;
  error?: string;
  invalidateDevice?: boolean;
}

export interface PushProvider {
  send(job: PushJob): Promise<PushResult>;
}

function base64Url(value: Uint8Array | string): string {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function pemBytes(value: string): Uint8Array {
  const normalized = value.replace(/\\n/g, "\n").replace(/-----[^-]+-----/g, "").replace(/\s/g, "");
  const binary = atob(normalized);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

let cachedToken: { token: string; issuedAt: number } | null = null;

async function apnsJwt(): Promise<string> {
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const keyId = Deno.env.get("APNS_KEY_ID");
  const privateKey = Deno.env.get("APNS_PRIVATE_KEY");
  if (!teamId || !keyId || !privateKey) throw new Error("Push credentials are not configured");
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now - cachedToken.issuedAt < 50 * 60) return cachedToken.token;
  const header = base64Url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const payload = base64Url(JSON.stringify({ iss: teamId, iat: now }));
  const signingInput = `${header}.${payload}`;
  const decodedKey = pemBytes(privateKey);
  const keyBytes = new Uint8Array(decodedKey.byteLength);
  keyBytes.set(decodedKey);
  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes.buffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  cachedToken = { token: `${signingInput}.${base64Url(new Uint8Array(signature))}`, issuedAt: now };
  return cachedToken.token;
}

export class MockPushProvider implements PushProvider {
  async send(job: PushJob): Promise<PushResult> {
    await Promise.resolve();
    return {
      outcome: "accepted",
      providerMessageId: `push_mock_${job.job_id.replaceAll("-", "")}`,
    };
  }
}

export class APNSPushProvider implements PushProvider {
  async send(job: PushJob): Promise<PushResult> {
    try {
      const jwt = await apnsJwt();
      const topic = Deno.env.get("APNS_TOPIC");
      if (!topic) throw new Error("Push topic is not configured");
      const host = job.environment === "production"
        ? "https://api.push.apple.com"
        : "https://api.sandbox.push.apple.com";
      const response = await fetch(`${host}/3/device/${encodeURIComponent(job.token)}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "content-type": "application/json",
          "apns-topic": topic,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-expiration": String(job.expiration_epoch),
          "apns-collapse-id": `daily-list-${job.job_id}`,
        },
        body: JSON.stringify({
          aps: {
            alert: { title: "Your list is ready", body: "Review your list and get it delivered." },
            sound: "default",
            "thread-id": "daily-list",
          },
          deep_link: job.deep_link,
        }),
      });
      const messageId = response.headers.get("apns-id") ?? undefined;
      if (response.ok) return { outcome: "accepted", providerMessageId: messageId };
      const payload = await response.json().catch(() => ({})) as { reason?: string };
      const invalid = response.status === 410 ||
        ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"]
          .includes(payload.reason ?? "");
      const retryable = response.status === 429 || response.status >= 500;
      return {
        outcome: invalid ? "failed" : retryable ? "retry" : "failed",
        providerMessageId: messageId,
        error: payload.reason ?? `Push request failed (${response.status})`,
        invalidateDevice: invalid,
      };
    } catch (error) {
      console.error("Push delivery failed", error);
      return {
        outcome: "retry",
        error: error instanceof Error ? error.message : "Push delivery failed",
      };
    }
  }
}

export function pushProvider(): PushProvider {
  return (Deno.env.get("PUSH_PROVIDER") ?? "mock") === "apns"
    ? new APNSPushProvider()
    : new MockPushProvider();
}
