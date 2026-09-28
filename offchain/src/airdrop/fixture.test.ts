import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fixtureJson, fixturePath } from "./fixture.js";

test("the Solidity airdrop fixture matches what the tree builder produces", () => {
  assert.equal(readFileSync(fixturePath, "utf8"), fixtureJson(), "run `npm run fixture` to regenerate it");
});
