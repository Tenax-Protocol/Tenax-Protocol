import assert from "node:assert/strict";
import { test } from "node:test";
import { findRoundAt, type ReadRound } from "./chainlink.js";

const id = (phase: bigint, round: bigint) => (phase << 64n) | round;

/** In-memory feed: a map from round id to its time. */
function feed(rounds: Array<[bigint, bigint]>): { read: ReadRound; latest: bigint } {
  const times = new Map(rounds);
  return { read: async (roundId) => times.get(roundId) ?? null, latest: rounds[rounds.length - 1]![0] };
}

test("returns the round whose time is the last one at or before the timestamp", async () => {
  const { read, latest } = feed([
    [id(1n, 1n), 100n],
    [id(1n, 2n), 200n],
    [id(1n, 3n), 300n],
    [id(1n, 4n), 400n],
  ]);
  assert.equal(await findRoundAt(read, latest, 250n), id(1n, 2n));
  assert.equal(await findRoundAt(read, latest, 300n), id(1n, 3n), "a round published exactly at the timestamp");
  assert.equal(await findRoundAt(read, latest, 100n), id(1n, 1n));
});

test("returns the latest round when it is already active", async () => {
  const { read, latest } = feed([
    [id(1n, 1n), 100n],
    [id(1n, 2n), 200n],
  ]);
  assert.equal(await findRoundAt(read, latest, 999n), id(1n, 2n));
});

test("returns null before the first round", async () => {
  const { read, latest } = feed([[id(1n, 1n), 100n]]);
  assert.equal(await findRoundAt(read, latest, 50n), null);
});

test("works with unphased ids, as mock aggregators use", async () => {
  const rounds: Array<[bigint, bigint]> = [];
  for (let i = 1n; i <= 1000n; i++) rounds.push([i, i * 10n]);
  const { read, latest } = feed(rounds);
  assert.equal(await findRoundAt(read, latest, 5555n), 555n);
});

test("searches an older phase and refuses its unprovable last round", async () => {
  const { read, latest } = feed([
    [id(1n, 1n), 100n],
    [id(1n, 2n), 200n],
    [id(1n, 3n), 300n],
    [id(2n, 1n), 500n],
    [id(2n, 2n), 600n],
  ]);
  assert.equal(await findRoundAt(read, latest, 250n), id(1n, 2n), "provable inside the old phase");
  assert.equal(await findRoundAt(read, latest, 400n), null, "the old phase's last round has no successor");
  assert.equal(await findRoundAt(read, latest, 550n), id(2n, 1n));
});

test("reads a logarithmic number of rounds", async () => {
  const rounds: Array<[bigint, bigint]> = [];
  for (let i = 1n; i <= 100_000n; i++) rounds.push([id(3n, i), i * 2n]);
  const { read: inner, latest } = feed(rounds);
  let reads = 0;
  const read: ReadRound = async (roundId) => {
    reads++;
    return inner(roundId);
  };
  assert.equal(await findRoundAt(read, latest, 123_457n), id(3n, 61_728n));
  assert.ok(reads < 25, `${reads} reads`);
});
