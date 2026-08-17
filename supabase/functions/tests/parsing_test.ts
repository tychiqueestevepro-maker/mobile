import { assert, assertEquals } from "@std/assert";
import { deterministicParse } from "../_shared/parsing.ts";

Deno.test("deterministic parser extracts durable black trash bags", () => {
  const intent = deterministicParse("I need strong black trash bags that won't rip");
  assertEquals(intent.category, "trash_bags");
  assertEquals(intent.quantity, 1);
  assert(intent.confidence > 0.9);
  assertEquals(intent.attributes.find((attribute) => attribute.name === "color")?.value, "black");
  assertEquals(
    intent.attributes.find((attribute) => attribute.name === "strength")?.value,
    "heavy-duty",
  );
});

Deno.test("deterministic parser asks only the material battery clarification", () => {
  const ambiguous = deterministicParse("Get me batteries");
  assertEquals(ambiguous.clarification?.question, "Which size?");
  assertEquals(ambiguous.clarification?.options, ["AA", "AAA", "Other"]);
  assertEquals(deterministicParse("Get me AA batteries").clarification, null);
});

Deno.test("deterministic parser extracts quantity and price ceiling", () => {
  const intent = deterministicParse("Get 2 mint toothpastes under $8");
  assertEquals(intent.category, "toothpaste");
  assertEquals(intent.quantity, 2);
  assertEquals(intent.max_price_cents, 800);
});
