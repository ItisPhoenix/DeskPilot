#!/usr/bin/env node
/**
 * DeskPilot does not expose the upstream feedback/analytics form to any client.
 * The generic get_prompts tool also remains intentionally unavailable.
 */
import { exitProcess } from "../dist/utils/exit-process.js";
import { connectToServer } from "./helpers/mcp-client.js";

async function assertNoUpstreamFeedback(clientName) {
  const client = await connectToServer(clientName);
  try {
    const response = await client.listTools();
    const names = response.tools.map((tool) => tool.name);
    if (names.includes("give_feedback_to_desktop_commander")) {
      throw new Error("Upstream feedback form must not be exposed");
    }
    if (names.includes("get_prompts")) {
      throw new Error("get_prompts must not be exposed");
    }
    console.log(`PASS ${clientName}: no upstream feedback or hidden prompt tools`);
  } finally {
    await client.close();
  }
}

async function run() {
  await assertNoUpstreamFeedback("test-client");
  await assertNoUpstreamFeedback("desktop-commander-app");
}

run().catch((error) => {
  console.error("Conditional tools test failed:", error);
  exitProcess(1);
});
