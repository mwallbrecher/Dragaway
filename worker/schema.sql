-- AI Drop hosted free tier — D1 schema.
-- Apply with: wrangler d1 execute aidrop --remote --file=./schema.sql

-- One row per device (anonymous, identified by a client-generated UUID).
-- trial_used counts lifetime trial interactions consumed (capped at TRIAL_TOTAL).
CREATE TABLE IF NOT EXISTS accounts (
  device_id   TEXT PRIMARY KEY,
  trial_used  INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Per-device, per-UTC-day interaction count (used once the trial is exhausted).
CREATE TABLE IF NOT EXISTS usage (
  device_id  TEXT NOT NULL,
  day        TEXT NOT NULL,          -- 'YYYY-MM-DD' in UTC
  count      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device_id, day)
);

-- Global per-UTC-day total — the budget circuit-breaker.
CREATE TABLE IF NOT EXISTS global_usage (
  day    TEXT PRIMARY KEY,           -- 'YYYY-MM-DD' in UTC
  count  INTEGER NOT NULL DEFAULT 0
);
