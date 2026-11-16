-- Palaver's opt-in usage numbers (#6): one row per UTC day and install, nothing else.
-- `install` is the hex SHA-256 of the Worker's secret SALT and the app's random install id: the id itself is never
-- stored. No IP address, no user agent, no time of day.
CREATE TABLE IF NOT EXISTS pings (
  day TEXT NOT NULL,      -- the UTC day the ping arrived, YYYY-MM-DD
  install TEXT NOT NULL,  -- salted SHA-256 of the install id, 64 hex digits
  version TEXT NOT NULL,  -- Palaver's version, e.g. 0.6.8
  macos TEXT NOT NULL,    -- macOS major.minor, e.g. 15.5
  PRIMARY KEY (day, install)
) WITHOUT ROWID;
