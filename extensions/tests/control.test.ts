// Tests for extensions/pocketpi-control.ts with a fake pi. Run:
// node --test 'extensions/tests/*.test.ts'
import { test } from "node:test";
import assert from "node:assert/strict";
import control, { FILE_REFERENCE_PROMPT } from "../pocketpi-control.ts";
import { fakePi } from "./modes-fake.ts";

test("every turn gets the @-path rule as a system prompt section", async () => {
  const f = fakePi();
  control(f.pi);
  const first = await f.startPrompt("look at @src/main.rs");
  assert.equal(first.pocketpi_file_references, FILE_REFERENCE_PROMPT);
  assert.match(FILE_REFERENCE_PROMPT, /do not claim to have inspected it before reading/);
  // The same text without a mention: the prompt (and its cache) don't change.
  const second = await f.startPrompt("thanks");
  assert.equal(second.pocketpi_file_references, first.pocketpi_file_references);
});

test("a turn without prompt sections is left alone", async () => {
  const f = fakePi();
  control(f.pi);
  await f.emit("before_agent_start", { messageType: "user", prompt: "hi", systemPrompt: "" });
});

test("the control commands still answer", async () => {
  const f = fakePi();
  control(f.pi);
  await assert.rejects(f.control("label", {}), /entryId is required/);
});
