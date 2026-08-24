#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const ROOT = process.env.ORBS_HOME || join(homedir(), ".orbs");
const REG = join(ROOT, "registry.json");

function load() {
  if (!existsSync(REG)) return { orbs: {} };
  try {
    return JSON.parse(readFileSync(REG, "utf8"));
  } catch {
    return { orbs: {} };
  }
}

function save(db) {
  mkdirSync(ROOT, { recursive: true });
  writeFileSync(REG, JSON.stringify(db, null, 2) + "\n");
}

const [cmd, ...args] = process.argv.slice(2);
const db = load();
const now = () => new Date().toISOString();

switch (cmd) {
  case "add": {
    const id = args[0];
    const entry = JSON.parse(args[1]);
    if (db.orbs[id]) {
      console.error(`orb ${id} already registered`);
      process.exit(1);
    }
    entry.id = id;
    entry.created = now();
    entry.last_active = now();
    db.orbs[id] = entry;
    save(db);
    console.log(JSON.stringify(db.orbs[id], null, 2));
    break;
  }
  case "list": {
    console.log(JSON.stringify(Object.values(db.orbs), null, 2));
    break;
  }
  case "get": {
    const e = db.orbs[args[0]];
    if (!e) {
      console.error(`orb ${args[0]} not found`);
      process.exit(1);
    }
    console.log(JSON.stringify(e, null, 2));
    break;
  }
  case "update": {
    const id = args[0];
    const patch = JSON.parse(args[1]);
    if (!db.orbs[id]) {
      console.error(`orb ${id} not found`);
      process.exit(1);
    }
    db.orbs[id] = { ...db.orbs[id], ...patch, id };
    save(db);
    console.log(JSON.stringify(db.orbs[id], null, 2));
    break;
  }
  case "remove": {
    if (!db.orbs[args[0]]) {
      console.error(`orb ${args[0]} not found`);
      process.exit(1);
    }
    delete db.orbs[args[0]];
    save(db);
    console.log("removed");
    break;
  }
  case "path": {
    console.log(REG);
    break;
  }
  default:
    console.error("usage: orb-registry.mjs <add|list|get|update|remove|path> ...");
    process.exit(2);
}
