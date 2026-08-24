#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";

const [src, dst] = process.argv.slice(2);
if (!src || !dst) {
  console.error("usage: orb-config.mjs <src-opencode.json> <dst-opencode.json>");
  process.exit(2);
}
const raw = readFileSync(src, "utf8");
const cleaned = raw.replace(/,\s*([}\]])/g, "$1");
let cfg;
try {
  cfg = JSON.parse(cleaned);
} catch (e) {
  console.error(`cannot parse ${src}: ${e.message}`);
  process.exit(1);
}

const fix = (o) => {
  if (Array.isArray(o)) {
    o.forEach(fix);
    return o;
  }
  if (o && typeof o === "object") {
    for (const k in o) o[k] = fix(o[k]);
    return o;
  }
  return typeof o === "string"
    ? o.replace(/https?:\/\/(localhost|127\.0\.0\.1):/g, "http://host.docker.internal:")
    : o;
};
fix(cfg);

cfg.permission = {
  ...(cfg.permission || {}),
  bash: "allow",
  edit: "allow",
  webfetch: "allow",
  websearch: "allow",
  task: "allow",
};
writeFileSync(dst, JSON.stringify(cfg, null, 2) + "\n");
console.log(dst);
