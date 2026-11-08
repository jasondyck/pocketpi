// Prints pi's built-in providers, one JSON line each: id, name, whether they
// take an API key / have an OAuth sign-in (and if it's a subscription), and
// the env vars pi reads a key from. src/pi_providers.rs's KNOWN table is made
// from this (plus llama.cpp, which an extension adds); rerun after a pi update:
//
//   node scripts/pi-providers.mjs [path to @earendil-works/pi-ai/dist]
//
// It only imports pi-ai's provider definitions; it reads no credentials.
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const dist = process.argv[2] ||
  join(execFileSync("npm", ["root", "-g"]).toString().trim(), "@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist");
const all = await import(pathToFileURL(join(dist, "providers/all.js")).href);
const env = await import(pathToFileURL(join(dist, "env-api-keys.js")).href);
// findEnvKeys(provider, env) returns the variables that are set; with an
// environment where everything is set, that's all of them.
const everything = new Proxy({}, { get: () => "x", has: () => true });
for (const p of all.builtinProviders()) {
  console.log(JSON.stringify({
    id: p.id,
    name: p.name,
    apiKey: !!p.auth?.apiKey,
    oauth: !!p.auth?.oauth,
    subscription: !!p.auth?.oauth?.isSubscription,
    env: env.findEnvKeys(p.id, everything) || [],
  }));
}
