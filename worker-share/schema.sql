-- Dragaway Share — D1 schema.
-- Apply with: wrangler d1 execute dragaway-share --remote --file=./schema.sql
--
-- Only metadata lives here. The ciphertext itself sits in KV (self-expiring).
-- Deleting a row makes a share unreachable even if bytes linger anywhere.

CREATE TABLE IF NOT EXISTS shares (
  code         TEXT PRIMARY KEY,      -- the 6 digits the user types
  tier         TEXT NOT NULL,         -- 'codeOnly' | 'password'
  enc_key      TEXT,                  -- codeOnly ONLY: base64 AES key the server releases
                                      -- on the correct code. NULL in the password tier —
                                      -- that is what makes the password tier end-to-end.
  salt         TEXT,                  -- password tier: KDF salt (public by design)
  file_name    TEXT NOT NULL DEFAULT '',
  has_password INTEGER NOT NULL DEFAULT 0,
  attempts     INTEGER NOT NULL DEFAULT 0,   -- wrong-code guesses; locks at 10
  fetches      INTEGER NOT NULL DEFAULT 0,   -- successful downloads; stops at 5
  created_at   INTEGER NOT NULL,      -- unix seconds
  expires_at   INTEGER NOT NULL       -- unix seconds; swept hourly by the cron trigger
);

CREATE INDEX IF NOT EXISTS idx_shares_expiry ON shares (expires_at);
