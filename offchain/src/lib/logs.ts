/** Fetches the entries of the blocks `[from, to]`, both inclusive. */
export type QueryRange<T> = (from: bigint, to: bigint) => Promise<T[]>;

/**
 * Queries the blocks `[from, to]` in ranges of at most `chunk` blocks. Providers cap the range of a log query (the
 * public Base endpoints at 1,000 blocks, some dedicated RPCs lower), so a rejected query is retried with half the
 * range, down to a single block, and the smaller range is kept for the rest of the scan.
 */
export async function scanRanges<T>(from: bigint, to: bigint, chunk: bigint, query: QueryRange<T>): Promise<T[]> {
  const entries: T[] = [];
  let size = chunk;
  for (let start = from; start <= to; ) {
    const end = start + size - 1n < to ? start + size - 1n : to;
    try {
      entries.push(...(await query(start, end)));
      start = end + 1n;
    } catch (error) {
      if (end === start) throw error;
      size = (end - start + 1n) / 2n;
    }
  }
  return entries;
}
