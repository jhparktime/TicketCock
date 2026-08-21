import { fetchLiveNearbySuwonStores, savePreloadedSuwonStores, type ReturnedStore } from "../server.js";

/**
 * Daily public-data refresh for the Suwon MVP.
 *
 * The grid keeps data.go.kr calls out of the mobile request path. A non-empty existing directory
 * is never overwritten with an empty/partial run. Each point is rate-paced by the shared live
 * fetcher; the Cloud Run Job has a 30-minute timeout in Terraform.
 */
const SUWON_GRID = [
  [37.185, 126.915], [37.185, 126.945], [37.185, 126.975], [37.185, 127.005], [37.185, 127.035], [37.185, 127.065], [37.185, 127.095], [37.185, 127.125], [37.185, 127.145],
  [37.210, 126.915], [37.210, 126.945], [37.210, 126.975], [37.210, 127.005], [37.210, 127.035], [37.210, 127.065], [37.210, 127.095], [37.210, 127.125], [37.210, 127.145],
  [37.235, 126.915], [37.235, 126.945], [37.235, 126.975], [37.235, 127.005], [37.235, 127.035], [37.235, 127.065], [37.235, 127.095], [37.235, 127.125], [37.235, 127.145],
  [37.260, 126.915], [37.260, 126.945], [37.260, 126.975], [37.260, 127.005], [37.260, 127.035], [37.260, 127.065], [37.260, 127.095], [37.260, 127.125], [37.260, 127.145],
  [37.285, 126.915], [37.285, 126.945], [37.285, 126.975], [37.285, 127.005], [37.285, 127.035], [37.285, 127.065], [37.285, 127.095], [37.285, 127.125], [37.285, 127.145],
  [37.310, 126.915], [37.310, 126.945], [37.310, 126.975], [37.310, 127.005], [37.310, 127.035], [37.310, 127.065], [37.310, 127.095], [37.310, 127.125], [37.310, 127.145],
  [37.335, 126.915], [37.335, 126.945], [37.335, 126.975], [37.335, 127.005], [37.335, 127.035], [37.335, 127.065], [37.335, 127.095], [37.335, 127.125], [37.335, 127.145]
] as const;

async function run() {
  if (process.env.STORE_SYNC_SCOPE && process.env.STORE_SYNC_SCOPE !== "suwon") {
    throw new Error("Only the Suwon MVP scope is allowed for this job");
  }
  const stores = new Map<string, ReturnedStore>();
  let successfulCells = 0;
  for (const [lat, lon] of SUWON_GRID) {
    try {
      const result = await fetchLiveNearbySuwonStores(lat, lon, 1_500, undefined, 20);
      result.forEach((store) => stores.set(store.id, store));
      successfulCells += 1;
    } catch (error) {
      console.warn("store sync grid cell skipped", { lat, lon, reason: error instanceof Error ? error.message : "unknown" });
    }
  }
  // Do not publish a one-cell response as a citywide directory; preserve the last known good data.
  if (successfulCells < Math.ceil(SUWON_GRID.length * 0.7) || stores.size === 0) {
    throw new Error(`Store sync quality gate failed: ${successfulCells}/${SUWON_GRID.length} cells, ${stores.size} stores`);
  }
  const saved = await savePreloadedSuwonStores([...stores.values()], "cloud-scheduler-store-sync");
  console.log(JSON.stringify({ event: "store_directory_synced", successfulCells, gridCells: SUWON_GRID.length, ...saved }));
}

await run();
