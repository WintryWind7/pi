/**
 * Custom system prompt: injects system-prompt.txt for every agent turn.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

export default function (pi: ExtensionAPI) {
  const promptPath = join(__dirname, "system-prompt.txt");
  let customPrompt: string | null = null;
  try {
    customPrompt = readFileSync(promptPath, "utf8");
  } catch { /* prompt file not found, use default */ }

  if (customPrompt) {
    pi.on("before_agent_start", async () => {
      return { systemPrompt: customPrompt! };
    });
  }
}
