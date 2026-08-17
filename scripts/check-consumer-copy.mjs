import { readdir, readFile } from "node:fs/promises";
import { extname, join } from "node:path";

const roots = ["ios/Needs/Features", "ios/Needs/Resources"];
const forbidden = ["OpenAI", "Supabase", "Uber", "GPT", "LLM"];
const extensions = new Set([".swift", ".strings", ".xcstrings"]);
const findings = [];

async function walk(path) {
  let entries;
  try {
    entries = await readdir(path, { withFileTypes: true });
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }

  for (const entry of entries) {
    const child = join(path, entry.name);
    if (entry.isDirectory()) {
      await walk(child);
    } else if (extensions.has(extname(entry.name))) {
      const text = await readFile(child, "utf8");
      for (const term of forbidden) {
        if (text.toLocaleLowerCase("en-US").includes(term.toLocaleLowerCase("en-US"))) {
          findings.push(`${child}: contains forbidden consumer term ${term}`);
        }
      }
    }
  }
}

for (const root of roots) await walk(root);

if (findings.length) {
  console.error(findings.join("\n"));
  process.exitCode = 1;
} else {
  console.log("Consumer copy check passed.");
}

