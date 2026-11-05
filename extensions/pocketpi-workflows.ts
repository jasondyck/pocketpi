// pocketpi-workflows: lets pi create, list and run pocketpi workflows from a
// chat. Talks to the local pocketpi server. New workflows are saved disabled
// (drafts) so their sensors never fire until the user enables them in the app.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const BASE = process.env.POCKETPI_URL || "http://127.0.0.1:3457";

async function call(path: string, body?: unknown): Promise<any> {
  const res = await fetch(BASE + path, {
    method: body === undefined ? "GET" : "POST",
    headers: body === undefined ? {} : { "content-type": "application/json", "x-pocketpi": "1" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${res.status} ${text}`);
  return text ? JSON.parse(text) : {};
}

const text = (s: string, details: Record<string, unknown> = {}) => ({ content: [{ type: "text" as const, text: s }], details });

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "workflow_guide",
    label: "Workflow guide",
    description:
      "Get the pocketpi workflow format (stages, sensors, templates, models), the user's projects and existing workflows. Call this before writing a workflow.",
    parameters: Type.Object({}),
    async execute() {
      const [schema, projects, wfs] = await Promise.all([call("/api/workflows/schema"), call("/api/projects"), call("/api/workflows")]);
      const existing = (wfs.workflows || []).map((w: any) => `- ${w.workflow.id}: ${w.workflow.name} (${w.workflow.project})${w.workflow.enabled ? "" : " [draft]"}`);
      return text(
        `WORKFLOW FORMAT\n${JSON.stringify(schema, null, 1)}\n\nPROJECTS (use these paths for "project")\n${(projects.projects || [])
          .map((p: any) => `- ${p.name}: ${p.path}`)
          .join("\n")}\n\nEXISTING WORKFLOWS\n${existing.join("\n") || "(none)"}\n\nGuidance: keep stages few and purposeful; use the subscription models first (grok-4.7 to plan and implement, gpt-6.1-sol to review) and deepseek-v4.1-flash for cheap mechanical stages; never Muse Spark (trains on data); add a review stage and an approval gate before anything that pushes, merges or deploys; give shell checks on_fail loop-backs to the stage that can fix them; set max_cost.`,
      );
    },
  });

  pi.registerTool({
    name: "workflow_save",
    label: "Save workflow",
    description:
      "Validate and save a pocketpi workflow (create or replace by id). It is saved as a disabled draft; the user reviews and enables it in pocketpi. Returns validation errors to fix if invalid.",
    parameters: Type.Object({
      workflow: Type.Any({ description: "The full workflow object in the format from workflow_guide." }),
    }),
    async execute(_id, params) {
      const wf = typeof params.workflow === "string" ? JSON.parse(params.workflow) : params.workflow;
      if (wf && typeof wf === "object") {
        const prev = await call(`/api/workflows/${encodeURIComponent(wf.id || "")}`).catch(() => null);
        wf.enabled = prev?.workflow?.enabled === true; // never auto-enable sensors
      }
      const r = await call("/api/workflows", wf);
      if (!r.ok) return text(`Not saved. Fix these problems and call workflow_save again:\n- ${(r.errors || []).join("\n- ")}`, { ok: false, errors: r.errors });
      const w = r.workflow;
      const stages = w.stages.map((s: any) => `${s.id} (${s.type}${s.needs?.length ? ` after ${s.needs.join(", ")}` : ""})`).join(" → ");
      return text(
        `Saved workflow "${w.name}" (${w.id}) as ${w.enabled ? "enabled" : "a draft"}. Stages: ${stages}. Tell the user they can open it in pocketpi to review, enable sensors, or run it.`,
        { ok: true, workflow: w },
      );
    },
  });

  pi.registerTool({
    name: "workflow_list",
    label: "List workflows",
    description: "List the user's pocketpi workflows with their last run status.",
    parameters: Type.Object({}),
    async execute() {
      const r = await call("/api/workflows");
      const lines = (r.workflows || []).map(
        (w: any) => `- ${w.workflow.id}: ${w.workflow.name}${w.workflow.enabled ? "" : " [draft]"}; last run: ${w.last_run ? w.last_run.status : "never"}`,
      );
      return text(lines.join("\n") || "No workflows yet.", r);
    },
  });

  pi.registerTool({
    name: "workflow_run",
    label: "Run workflow",
    description: "Start a run of a pocketpi workflow by id, with optional inputs. Only do this when the user asks for a run.",
    parameters: Type.Object({
      id: Type.String(),
      inputs: Type.Optional(Type.Record(Type.String(), Type.String())),
    }),
    async execute(_id, params) {
      const r = await call(`/api/workflows/${encodeURIComponent(params.id)}/run`, { inputs: params.inputs || {}, trigger: "chat" });
      return text(`Started run ${r.run_id}. The user can follow it live in pocketpi.`, { run_id: r.run_id, workflow_id: params.id });
    },
  });
}
