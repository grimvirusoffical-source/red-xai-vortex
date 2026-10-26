CREATE TABLE IF NOT EXISTS counts (
  item TEXT NOT NULL,
  platform TEXT NOT NULL,
  n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (item, platform)
);

CREATE TABLE IF NOT EXISTS rl (
  ip TEXT NOT NULL,
  item TEXT NOT NULL,
  bucket INTEGER NOT NULL,
  PRIMARY KEY (ip, item, bucket)
);

CREATE TABLE IF NOT EXISTS items (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  href TEXT NOT NULL,
  gh_owner TEXT,
  gh_repo TEXT,
  gh_tag TEXT,
  gh_file TEXT
);

CREATE TABLE IF NOT EXISTS gh (
  item TEXT PRIMARY KEY,
  download_count INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL
);
