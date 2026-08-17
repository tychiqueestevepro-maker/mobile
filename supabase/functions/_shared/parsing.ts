import { AppError } from "./http.ts";
import type { IntentAttribute, NeedIntent } from "./types.ts";

const CATEGORY_TERMS: Array<[string, string[]]> = [
  ["trash_bags", ["trash bag", "garbage bag", "bin liner"]],
  ["toothpaste", ["toothpaste", "tooth paste"]],
  ["toilet_paper", ["toilet paper", "bath tissue"]],
  ["eggs", ["egg"]],
  ["milk", ["milk"]],
  ["bottled_water", ["bottled water", "water bottles"]],
  ["paper_towels", ["paper towel", "kitchen roll"]],
  ["dish_soap", ["dish soap", "washing up liquid"]],
  ["laundry_detergent", ["laundry detergent", "washing detergent"]],
  ["shampoo", ["shampoo"]],
  ["batteries", ["battery", "batteries"]],
  ["pasta", ["pasta", "spaghetti", "penne"]],
  ["coffee", ["coffee"]],
  ["hand_soap", ["hand soap"]],
];

function attribute(name: string, value: string | null): IntentAttribute[] {
  return value ? [{ name, value }] : [];
}

export function deterministicParse(input: string): NeedIntent {
  const text = input.toLowerCase().replace(/[^a-z0-9$ .-]/g, " ").replace(/\s+/g, " ").trim();
  const category =
    CATEGORY_TERMS.find(([, terms]) => terms.some((term) => text.includes(term)))?.[0] ?? "other";
  const attributes: IntentAttribute[] = [];
  const add = (name: string, value: string | null) => attributes.push(...attribute(name, value));
  add("color", ["black", "white", "green"].find((value) => text.includes(value)) ?? null);
  add("strength", /strong|durable|won.t rip|heavy duty/.test(text) ? "heavy-duty" : null);
  add(
    "scent",
    /unscented|fragrance[ -]?free/.test(text)
      ? "unscented"
      : text.includes("citrus")
      ? "citrus"
      : null,
  );
  add("sensitivity", /sensitive|gentle/.test(text) ? "yes" : null);
  add("material", /recycled|eco/.test(text) ? "recycled" : null);
  add("flavor", text.includes("mint") ? "mint" : null);
  const quantityMatch = text.match(/\b(\d{1,2})\b/);
  const quantity = Math.max(1, Math.min(99, quantityMatch ? Number(quantityMatch[1]) : 1));
  const sizeMatch = text.match(/(\d+(?:\.\d+)?)\s*(gal|gallon|oz|fl oz|count|ct|ml|l)\b/);
  const priceMatch = text.match(
    /(?:under|below|max(?:imum)?|less than)\s*\$\s*(\d+(?:\.\d{1,2})?)/,
  );
  const brandMatch = text.match(/\bbrand\s+([a-z][a-z0-9-]{1,30})\b/);
  const format = ["drawstring", "tablets", "paste", "pods", "liquid", "roll"]
    .find((value) => text.includes(value)) ?? null;
  const needsBatteryClarification = category === "batteries" && !/\b(aa|aaa|c|d|9v)\b/i.test(input);
  return {
    category,
    normalized_query: text,
    attributes,
    quantity,
    confidence: category === "other" ? 0.55 : 0.92,
    brand: brandMatch?.[1] ?? null,
    format,
    size_value: sizeMatch ? Number(sizeMatch[1]) : null,
    size_unit: sizeMatch?.[2]?.replace("gallon", "gal").replace("ct", "count") ?? null,
    max_price_cents: priceMatch ? Math.round(Number(priceMatch[1]) * 100) : null,
    clarification: needsBatteryClarification
      ? { question: "Which size?", options: ["AA", "AAA", "Other"] }
      : null,
  };
}

const intentSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    category: { type: "string", minLength: 1, maxLength: 80 },
    normalized_query: { type: "string", minLength: 1, maxLength: 300 },
    attributes: {
      type: "array",
      maxItems: 12,
      items: {
        type: "object",
        additionalProperties: false,
        properties: { name: { type: "string" }, value: { type: "string" } },
        required: ["name", "value"],
      },
    },
    quantity: { type: "integer", minimum: 1, maximum: 99 },
    confidence: { type: "number", minimum: 0, maximum: 1 },
    brand: { type: ["string", "null"] },
    format: { type: ["string", "null"] },
    size_value: { type: ["number", "null"], minimum: 0 },
    size_unit: { type: ["string", "null"] },
    max_price_cents: { type: ["integer", "null"], minimum: 0 },
    clarification: {
      anyOf: [
        { type: "null" },
        {
          type: "object",
          additionalProperties: false,
          properties: {
            question: { type: "string" },
            options: { type: "array", minItems: 2, maxItems: 4, items: { type: "string" } },
          },
          required: ["question", "options"],
        },
      ],
    },
  },
  required: [
    "category",
    "normalized_query",
    "attributes",
    "quantity",
    "confidence",
    "brand",
    "format",
    "size_value",
    "size_unit",
    "max_price_cents",
    "clarification",
  ],
} as const;

function outputText(response: Record<string, unknown>): string | null {
  if (typeof response.output_text === "string") return response.output_text;
  const output = Array.isArray(response.output) ? response.output : [];
  for (const item of output as Array<Record<string, unknown>>) {
    const content = Array.isArray(item.content) ? item.content : [];
    for (const part of content as Array<Record<string, unknown>>) {
      if (part.type === "output_text" && typeof part.text === "string") return part.text;
    }
  }
  return null;
}

function validateIntent(value: unknown): NeedIntent {
  if (!value || typeof value !== "object") {
    throw new AppError(502, "parse_failed", "We couldn't understand that request.");
  }
  const intent = value as NeedIntent;
  if (
    typeof intent.category !== "string" || typeof intent.normalized_query !== "string" ||
    !Array.isArray(intent.attributes) || !Number.isInteger(intent.quantity) ||
    typeof intent.confidence !== "number"
  ) throw new AppError(502, "parse_failed", "We couldn't understand that request.");
  return intent;
}

export async function parseNeed(input: string): Promise<NeedIntent> {
  const mode = Deno.env.get("PARSER_MODE") ?? "deterministic";
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (mode !== "openai" || !apiKey) return deterministicParse(input);

  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify({
      model: Deno.env.get("OPENAI_MODEL") ?? "gpt-5.6-luna",
      store: false,
      reasoning: { effort: "low" },
      input: [
        {
          role: "developer",
          content: [{
            type: "input_text",
            text:
              "Extract a household shopping need. Preserve explicit constraints. Do not invent a brand, size, price, or attribute. Ask at most one clarification and only when no useful product search is possible.",
          }],
        },
        { role: "user", content: [{ type: "input_text", text: input }] },
      ],
      text: {
        format: {
          type: "json_schema",
          name: "need_intent",
          description: "A normalized household product request.",
          schema: intentSchema,
          strict: true,
        },
      },
    }),
  });
  if (!response.ok) {
    console.error("Intent provider request failed", {
      status: response.status,
      body: await response.text(),
    });
    throw new AppError(502, "parse_unavailable", "We couldn't understand that request right now.");
  }
  const payload = await response.json() as Record<string, unknown>;
  const text = outputText(payload);
  if (!text) throw new AppError(502, "parse_failed", "We couldn't understand that request.");
  try {
    return validateIntent(JSON.parse(text));
  } catch (error) {
    if (error instanceof AppError) throw error;
    throw new AppError(502, "parse_failed", "We couldn't understand that request.");
  }
}
