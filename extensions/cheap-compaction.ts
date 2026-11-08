// cheap-compaction: summarize the conversation with a cheap model instead of
// the active one. grok-4.7 / gpt-6.1-sol cost $2/M in and $6-10/M out, while
// deepseek-v4.1-flash is $0.15/$0.60, so long sessions compact for ~10x less.
// The conversation model is unchanged; only the summarization request routes
// elsewhere. Any failure falls back to pi's default compaction.
//
// Settings (env): PI_COMPACTION_MODELS is the comma-separated order, tried
// until one returns a non-empty summary (default: flash, then pro).

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { convertToLlm, serializeConversation } from "@earendil-works/pi-coding-agent";

const MODELS = (process.env.PI_COMPACTION_MODELS || "opencode-go/deepseek-v4.1-flash,opencode-go/deepseek-v4-pro")
  .split(",")
  .map((m) => m.trim())
  .filter(Boolean);

const MAX_SUMMARY_TOKENS = 8192;

const PROMPT = (conversation: string, previous?: string, custom?: string) => `You are compacting a coding-session transcript so the agent can continue the work from your summary alone.
${previous ? `\nEarlier summary for context:\n${previous}\n` : ""}
Capture, concisely but completely:
1. The goal and the user's constraints/preferences
2. Decisions made and why, including alternatives rejected
3. Files, paths, commands and code changes that matter, with exact names
4. Current state of the work and anything half-finished
5. Errors, blockers and open questions
6. Next steps already agreed on
${custom ? `\nExtra focus requested for this compaction:\n${custom}\n` : ""}

Write structured markdown. Do not invent anything, and do not repeat large code blocks verbatim.

<conversation>
${conversation}
</conversation>`;

export default function (pi: ExtensionAPI) {
  pi.on("session_before_compact", async (event, ctx) => {
    const { preparation, signal, customInstructions } = event;
    const { messagesToSummarize, turnPrefixMessages, tokensBefore, firstKeptEntryId, previousSummary } = preparation;

    const messages = [...messagesToSummarize, ...turnPrefixMessages];
    if (messages.length === 0) return;

    const text = serializeConversation(convertToLlm(messages));
    const prompt = PROMPT(text, previousSummary, customInstructions);

    for (const ref of MODELS) {
      const [provider, ...rest] = ref.split("/");
      const model = ctx.modelRegistry.find(provider, rest.join("/"));
      if (!model) continue;

      try {
        const response = await ctx.modelRegistry.complete(
          model,
          { messages: [{ role: "user", content: [{ type: "text", text: prompt }], timestamp: Date.now() }] },
          { maxTokens: MAX_SUMMARY_TOKENS, signal, cacheRetention: "none" },
        );

        const summary = response.content
          .filter((c): c is { type: "text"; text: string } => c.type === "text")
          .map((c) => c.text)
          .join("\n")
          .trim();
        if (!summary) continue;

        ctx.ui.notify(`Compacted ${tokensBefore.toLocaleString()} tokens with ${ref}`, "info");
        return { compaction: { summary, firstKeptEntryId, tokensBefore, usage: response.usage } };
      } catch (error) {
        if (signal.aborted) return;
        const message = error instanceof Error ? error.message : String(error);
        ctx.ui.notify(`${ref} failed to summarize (${message}), trying next`, "warning");
      }
    }
    return;
  });
}
