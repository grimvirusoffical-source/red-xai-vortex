import { workerData, parentPort } from "node:worker_threads";
import { openSqlite } from "../src/sqlite.mjs";
import { ensureSchema, recordHit } from "../src/store.mjs";

const db = openSqlite(workerData.db);
await ensureSchema(db);
let counted = 0;
for (let i = 0; i < workerData.n; i++) {
  const result = await recordHit(db, {
    ip: workerData.ip,
    href: workerData.href,
    ua: workerData.ua,
    now: 1_700_000_000_000 + i * 20_000,
    windowSec: 15,
  });
  if (result.counted) counted += 1;
}
parentPort.postMessage({ counted });
