// subscription-fallback: use subscription models (Grok, ChatGPT) first and only
// fall back to OpenCode Go when one hits its usage limit. When a turn on a
// subscription provider ends with a usage-limit / rate-limit error (after pi's
// own retries), the chat switches to the fallback model and continues.
// New chats still start on the default subscription model.
//
// Settings (env):
//   PI_SUB_FALLBACK            fallback model, default opencode-go/glm-5.2
//   PI_SUB_FALLBACK_PROVIDERS  comma list, default xai,openai,openai-codex

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const FALLBACK = process.env.PI_SUB_FALLBACK || "opencode-go/glm-5.2";
const PROVIDERS = (process.env.PI_SUB_FALLBACK_PROVIDERS || "xai,openai,openai-codex").split(",").map((s) => s.trim());
const LIMIT = /(usage limit|rate.?limit|quota|limit (reached|exceeded)|too many requests|\b429\b|weekly|exceeded your|insufficient|out of credits|resource.?exhausted)/i;

export default function (pi: ExtensionAPI) {
  let switched: { from: string; to: string } | null = null;
  let lastStop = "";

  pi.on("message_end", async (event: any) => {
    if (event.message?.role === "assistant") lastStop = event.message.stopReason || "";
  });

  // Switch as soon as a subscription model reports a usage limit. pi's own
  // automatic retry then runs on the fallback model.
  pi.on("agent_end", async (event: any, ctx) => {
    const model = ctx.model;
    if (!model || !PROVIDERS.includes(model.provider)) return;
    const last = [...(event.messages || [])].reverse().find((m: any) => m.role === "assistant");
    if (!last || last.stopReason !== "error" || !LIMIT.test(last.errorMessage || "")) return;

    const [provider, ...rest] = FALLBACK.split("/");
    const target = ctx.modelRegistry.find(provider, rest.join("/"));
    if (!target) {
      ctx.ui.notify(`${model.id} hit its usage limit and the fallback ${FALLBACK} isn't available`, "error");
      return;
    }
    if (!(await pi.setModel(target))) {
      ctx.ui.notify(`${model.id} hit its usage limit; no credentials for ${FALLBACK}`, "error");
      return;
    }
    switched = { from: model.id, to: target.id };
    ctx.ui.notify(`${model.id} hit its usage limit, so this chat switched to ${target.id}`, "warning");
  });

  // If no retry picked the work back up on the fallback, ask it to continue.
  pi.on("agent_settled", async (event: any) => {
    const s = switched;
    switched = null;
    if (!s || event.aborted || lastStop !== "error") return;
    pi.sendUserMessage(
      `(The previous model, ${s.from}, stopped because its subscription usage limit was reached. You are ${s.to}; continue the task from where it stopped.)`,
    );
  });
}
