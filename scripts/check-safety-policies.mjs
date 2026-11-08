#!/usr/bin/env node
// Checks pocketpi's proposed gotgenes policies against the package's own JSON
// schema, with no dependencies (the subset of JSON Schema 2020-12 the schema
// uses: type, enum, const, properties, additionalProperties, propertyNames,
// required, items, maxItems, minimum, maximum, minLength, maxLength, pattern,
// anyOf, $ref to #/$defs).
//
//   node scripts/check-safety-policies.mjs <permissions.schema.json> [policy.json ...]
//
// With no policy files it checks extensions/safety/*.json. The schema comes
// from the package (npm pack @gotgenes/pi-permission-system, schemas/).
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const [schemaPath, ...files] = process.argv.slice(2);
if (!schemaPath) {
  console.error("usage: check-safety-policies.mjs <permissions.schema.json> [policy.json ...]");
  process.exit(2);
}
const schema = JSON.parse(readFileSync(schemaPath, "utf8"));
const here = dirname(fileURLToPath(import.meta.url));
const targets = files.length ? files : readdirSync(join(here, "../extensions/safety")).filter((f) => f.endsWith(".json")).map((f) => join(here, "../extensions/safety", f));

function typeOf(v) {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  if (Number.isInteger(v)) return "integer";
  return typeof v;
}
function typeOk(v, t) {
  const actual = typeOf(v);
  if (Array.isArray(t)) return t.some((x) => typeOk(v, x));
  return actual === t || (t === "number" && actual === "integer");
}
function resolve(ref) {
  if (!ref.startsWith("#/")) throw new Error(`unsupported $ref ${ref}`);
  return ref.slice(2).split("/").reduce((o, k) => o[k.replace(/~1/g, "/").replace(/~0/g, "~")], schema);
}
const KNOWN = new Set(["$schema", "$id", "$defs", "title", "description", "markdownDescription", "default", "examples", "deprecated",
  "type", "enum", "const", "properties", "additionalProperties", "propertyNames", "required", "items", "maxItems", "minimum", "maximum",
  "minLength", "maxLength", "pattern", "anyOf", "$ref"]);

// Returns a list of error strings.
function validate(v, s, at) {
  if (s === true || s === undefined) return [];
  if (s === false) return [`${at}: not allowed`];
  for (const k of Object.keys(s)) if (!KNOWN.has(k)) throw new Error(`schema keyword ${k} at ${at} isn't supported by this checker`);
  const errs = [];
  if (s.$ref) errs.push(...validate(v, resolve(s.$ref), at));
  if (s.type && !typeOk(v, s.type)) return [...errs, `${at}: expected ${s.type}, got ${typeOf(v)}`];
  if (s.enum && !s.enum.some((e) => JSON.stringify(e) === JSON.stringify(v))) errs.push(`${at}: ${JSON.stringify(v)} not one of ${JSON.stringify(s.enum)}`);
  if ("const" in s && JSON.stringify(s.const) !== JSON.stringify(v)) errs.push(`${at}: expected ${JSON.stringify(s.const)}`);
  if (typeof v === "number") {
    if (s.minimum !== undefined && v < s.minimum) errs.push(`${at}: below ${s.minimum}`);
    if (s.maximum !== undefined && v > s.maximum) errs.push(`${at}: above ${s.maximum}`);
  }
  if (typeof v === "string") {
    if (s.minLength !== undefined && [...v].length < s.minLength) errs.push(`${at}: shorter than ${s.minLength}`);
    if (s.maxLength !== undefined && [...v].length > s.maxLength) errs.push(`${at}: longer than ${s.maxLength}`);
    if (s.pattern && !new RegExp(s.pattern, "u").test(v)) errs.push(`${at}: doesn't match ${s.pattern}`);
  }
  if (Array.isArray(v)) {
    if (s.maxItems !== undefined && v.length > s.maxItems) errs.push(`${at}: more than ${s.maxItems} items`);
    if (s.items !== undefined) v.forEach((x, i) => errs.push(...validate(x, s.items, `${at}[${i}]`)));
  }
  if (typeOf(v) === "object") {
    for (const r of s.required || []) if (!(r in v)) errs.push(`${at}: missing ${r}`);
    for (const [k, x] of Object.entries(v)) {
      if (s.propertyNames) errs.push(...validate(k, s.propertyNames, `${at} key ${JSON.stringify(k)}`));
      if (s.properties && k in s.properties) errs.push(...validate(x, s.properties[k], `${at}.${k}`));
      else if (s.additionalProperties !== undefined) errs.push(...validate(x, s.additionalProperties, `${at}.${k}`));
    }
  }
  if (s.anyOf) {
    const results = s.anyOf.map((sub) => validate(v, sub, at));
    if (!results.some((r) => r.length === 0)) errs.push(`${at}: matches none of anyOf (${results.map((r) => r[0]).join(" | ")})`);
  }
  return errs;
}

// Things the schema can't say: a catch-all after a narrower rule shadows it
// (rules are last-match-wins).
function lint(doc) {
  const out = [];
  for (const [surface, rules] of Object.entries(doc.permission || {})) {
    if (rules && typeof rules === "object") {
      const keys = Object.keys(rules);
      const star = keys.indexOf("*");
      if (star > 0) out.push(`permission.${surface}: "*" comes after ${star} rule(s) and shadows them`);
    }
  }
  return out;
}

let bad = 0;
for (const f of targets) {
  const doc = JSON.parse(readFileSync(f, "utf8"));
  const errs = [...validate(doc, schema, "$"), ...lint(doc)];
  if (errs.length) {
    bad++;
    console.log(`✗ ${f}`);
    for (const e of errs) console.log(`    ${e}`);
  } else {
    console.log(`✓ ${f}`);
  }
}
process.exit(bad ? 1 : 0);
