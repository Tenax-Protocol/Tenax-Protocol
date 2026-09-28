// Runs every *.test.ts file under src with Node's test runner (Node 20 does not expand globs).
import { spawnSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { join } from "node:path";

const files = readdirSync("src", { recursive: true })
  .map(String)
  .filter((file) => file.endsWith(".test.ts"))
  .map((file) => join("src", file));
const result = spawnSync(process.execPath, ["--import", "tsx", "--test", ...files], { stdio: "inherit" });
process.exit(result.status ?? 1);
