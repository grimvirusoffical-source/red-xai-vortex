import { DatabaseSync } from "node:sqlite";

export function openSqlite(path) {
  const db = new DatabaseSync(path);
  db.exec("PRAGMA journal_mode = WAL");
  db.exec("PRAGMA busy_timeout = 5000");
  const api = {
    async exec(sql) {
      db.exec(sql);
    },
    async get(sql, params = []) {
      return db.prepare(sql).get(...params);
    },
    async all(sql, params = []) {
      return db.prepare(sql).all(...params);
    },
    async run(sql, params = []) {
      return db.prepare(sql).run(...params);
    },
    async transaction(fn) {
      const run = tail.then(async () => {
        db.exec("BEGIN IMMEDIATE");
        try {
          const value = await fn(api);
          db.exec("COMMIT");
          return value;
        } catch (error) {
          try { db.exec("ROLLBACK"); } catch { /* already closed */ }
          throw error;
        }
      });
      tail = run.then(() => {}, () => {});
      return run;
    },
  };
  let tail = Promise.resolve();
  return api;
}
