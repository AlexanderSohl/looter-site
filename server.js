// Reference leaderboard server for Top Down Looter.
// Serves the Unity WebGL build from ./public AND the API on the same origin.
// Runs are tied to website accounts (auth.js): only a signed-in session can submit.
// Still NOT cheat-proof: the numbers themselves are reported by the client (see README.md).

'use strict';

const path = require('path');
const express = require('express');
const Database = require('better-sqlite3');
const { installAuth } = require('./auth');

// ---------- Configuration (TUNING) ----------
const PORT = Number(process.env.PORT) || 8080;
const DATABASE_FILE = process.env.DATABASE_FILE || path.join(__dirname, 'leaderboard.sqlite');
const PUBLIC_DIRECTORY = path.join(__dirname, 'public');
const MAX_DISPLAY_NAME_LENGTH = 16;
const MAX_LIMIT = 100;
const DEFAULT_LIMIT = 50;
const MAX_TIER = 20;
const MAX_FLOOR = 1000;
const MAX_KILLS = 100000;
const MAX_GOLD = 100000000;
const MAX_DURATION_SECONDS = 86400;
const RATE_LIMIT_WINDOW_MS = 60 * 1000;
const RATE_LIMIT_MAX_REQUESTS = 30;
const JSON_BODY_LIMIT = '16kb';

// Leaderboard score weight per difficulty tier. KEEP IN SYNC with Assets/Game/Config/Definitions/dungeon_rules.json
// (difficultyTiers[].leaderboardScoreWeight and endlessTierScaling.leaderboardScoreWeightGrowthPerTier).
// Computed here from the tier instead of trusting a client-sent weight.
const TIER_SCORE_WEIGHTS = [1.0, 1.5, 2.2, 3.2, 4.6, 6.5];
const ENDLESS_SCORE_WEIGHT_GROWTH_PER_TIER = 1.4;

// Category API key -> SQL column. Whitelist: never put user text into SQL.
// weighted: multiply by the run's tier score weight. extractedOnly: only extracted runs count.
const CATEGORY_COLUMNS = {
  deepestFloor: { column: 'deepest_floor', weighted: true, extractedOnly: false },
  mostKills: { column: 'kills', weighted: true, extractedOnly: false },
  mostElitesKilled: { column: 'elites', weighted: true, extractedOnly: false },
  mostGoldExtracted: { column: 'gold', weighted: true, extractedOnly: true },
  highestDifficulty: { column: 'difficulty_tier', weighted: false, extractedOnly: false },
};

// ---------- Database ----------
const database = new Database(DATABASE_FILE);
database.pragma('journal_mode = WAL');
database.exec(`
  CREATE TABLE IF NOT EXISTS runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    player_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    difficulty_tier INTEGER NOT NULL,
    deepest_floor INTEGER NOT NULL,
    kills INTEGER NOT NULL,
    elites INTEGER NOT NULL,
    bosses INTEGER NOT NULL,
    gold INTEGER NOT NULL,
    duration_seconds REAL NOT NULL,
    extracted INTEGER NOT NULL,
    created_at TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS runs_player_index ON runs(player_id);
  -- Latest display name per player, so renaming shows up on every board right away.
  CREATE TABLE IF NOT EXISTS players (
    player_id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );
`);

// Migrations for databases created before ranked runs existed. Old rows count as ranked, weight 1.
const existingRunColumns = database.prepare('PRAGMA table_info(runs)').all().map((columnInfo) => columnInfo.name);
if (!existingRunColumns.includes('ranked')) {
  database.exec('ALTER TABLE runs ADD COLUMN ranked INTEGER NOT NULL DEFAULT 1');
}
if (!existingRunColumns.includes('score_weight')) {
  database.exec('ALTER TABLE runs ADD COLUMN score_weight REAL NOT NULL DEFAULT 1');
}

const upsertPlayer = database.prepare(`
  INSERT INTO players (player_id, display_name, updated_at) VALUES (@playerId, @displayName, @createdAt)
  ON CONFLICT(player_id) DO UPDATE SET display_name = excluded.display_name, updated_at = excluded.updated_at
`);

const insertRun = database.prepare(`
  INSERT INTO runs (player_id, display_name, difficulty_tier, deepest_floor, kills, elites, bosses, gold, duration_seconds, extracted, ranked, score_weight, created_at)
  VALUES (@playerId, @displayName, @difficultyTier, @deepestFloor, @kills, @elites, @bosses, @gold, @durationSeconds, @extracted, @ranked, @scoreWeight, @createdAt)
`);

// One prepared query per category: best value per player, then the display name and
// tier from that player's most recent run that reached the best value.
// Null prototype: ?category=constructor etc. must not match Object.prototype members.
const leaderboardQueries = Object.create(null);
// Unranked runs (easy-tier farming by a high-level player) never appear on a board.
for (const [apiKey, category] of Object.entries(CATEGORY_COLUMNS)) {
  const valueExpression = category.weighted
    ? `CAST(ROUND(MAX(runs.${category.column} * runs.score_weight)) AS INTEGER)`
    : `MAX(runs.${category.column})`;
  const extractedFilter = category.extractedOnly ? 'AND runs.extracted = 1' : '';
  leaderboardQueries[apiKey] = database.prepare(`
    SELECT runs.player_id AS playerId,
           COALESCE(players.display_name, runs.display_name) AS displayName,
           ${valueExpression} AS value,
           runs.difficulty_tier AS difficultyTier,
           runs.created_at AS submittedAtUtc
    FROM runs
    LEFT JOIN players ON players.player_id = runs.player_id
    WHERE runs.ranked = 1 ${extractedFilter}
    GROUP BY runs.player_id
    ORDER BY value DESC, runs.created_at ASC
    LIMIT ?
  `);
}

// ---------- Helpers ----------
function clampInteger(rawValue, minimum, maximum) {
  const parsed = Math.floor(Number(rawValue));
  if (!Number.isFinite(parsed)) {
    return minimum;
  }
  return Math.min(maximum, Math.max(minimum, parsed));
}

function clampNumber(rawValue, minimum, maximum) {
  const parsed = Number(rawValue);
  if (!Number.isFinite(parsed)) {
    return minimum;
  }
  return Math.min(maximum, Math.max(minimum, parsed));
}

function getScoreWeightForTier(tier) {
  if (tier <= TIER_SCORE_WEIGHTS.length) {
    return TIER_SCORE_WEIGHTS[tier - 1];
  }
  const lastWrittenWeight = TIER_SCORE_WEIGHTS[TIER_SCORE_WEIGHTS.length - 1];
  return lastWrittenWeight * Math.pow(ENDLESS_SCORE_WEIGHT_GROWTH_PER_TIER, tier - TIER_SCORE_WEIGHTS.length);
}

function cleanDisplayName(rawName) {
  const text = typeof rawName === 'string' ? rawName : '';
  const allowedOnly = text.replace(/[^\p{L}\p{N} _-]/gu, '').trim();
  return allowedOnly.slice(0, MAX_DISPLAY_NAME_LENGTH).trim();
}

// ---------- Tiny in-memory per-IP rate limit ----------
const requestTimesByIp = new Map();
function rateLimit(request, response, next) {
  const now = Date.now();
  const recentTimes = (requestTimesByIp.get(request.ip) || []).filter((time) => now - time < RATE_LIMIT_WINDOW_MS);
  if (recentTimes.length >= RATE_LIMIT_MAX_REQUESTS) {
    response.status(429).json({ error: 'Too many requests' });
    return;
  }
  recentTimes.push(now);
  requestTimesByIp.set(request.ip, recentTimes);
  next();
}
setInterval(() => {
  const now = Date.now();
  for (const [ip, times] of requestTimesByIp) {
    if (times.every((time) => now - time >= RATE_LIMIT_WINDOW_MS)) {
      requestTimesByIp.delete(ip);
    }
  }
}, RATE_LIMIT_WINDOW_MS).unref();

// ---------- App ----------
const app = express();
// Only trust X-Forwarded-For when a proxy (nginx/Caddy/Cloudflare) really sits in front:
// set TRUST_PROXY=1 (number of proxy hops). Exposed directly, clients could spoof it to dodge the rate limit.
if (process.env.TRUST_PROXY) {
  app.set('trust proxy', Number(process.env.TRUST_PROXY));
}

// Anti-clickjacking: only this site may frame its pages (the site itself frames the game).
// Kept to frame-ancestors only; a full CSP would need care for the Unity WebGL loader.
app.use((request, response, next) => {
  response.setHeader('Content-Security-Policy', "frame-ancestors 'self'");
  next();
});

// Public read-only CORS for the leaderboard so other pages can show it. Everything that
// writes (runs, accounts) is same-origin only and needs the session cookie.
app.use('/api/leaderboard', (request, response, next) => {
  response.setHeader('Access-Control-Allow-Origin', '*');
  response.setHeader('Access-Control-Allow-Methods', 'GET');
  next();
});

const { requireAccount, requireJson } = installAuth({
  app,
  database,
  rateLimit,
  cleanDisplayName,
  onDisplayNameChanged: (playerId, displayName) => upsertPlayer.run({ playerId, displayName, createdAt: new Date().toISOString() }),
});

app.post('/api/runs', rateLimit, requireAccount, requireJson, express.json({ limit: JSON_BODY_LIMIT }), (request, response) => {
  const body = request.body || {};
  const statistics = body.statistics;
  // Identity comes from the signed-in session, never from the body.
  const playerId = request.account.id;
  const displayName = request.account.display_name;

  if (!statistics || typeof statistics !== 'object') {
    response.status(400).json({ error: 'Invalid submission' });
    return;
  }

  const createdAt = new Date().toISOString();
  const difficultyTier = clampInteger(statistics.difficultyTier, 1, MAX_TIER);
  upsertPlayer.run({ playerId, displayName, createdAt });
  insertRun.run({
    playerId,
    displayName,
    difficultyTier,
    deepestFloor: clampInteger(statistics.deepestFloorReached, 0, MAX_FLOOR),
    kills: clampInteger(statistics.enemiesKilled, 0, MAX_KILLS),
    elites: clampInteger(statistics.elitesKilled, 0, MAX_KILLS),
    bosses: clampInteger(statistics.bossesKilled, 0, MAX_KILLS),
    gold: clampInteger(statistics.goldExtracted, 0, MAX_GOLD),
    durationSeconds: clampNumber(statistics.durationSeconds, 0, MAX_DURATION_SECONDS),
    extracted: statistics.extracted ? 1 : 0,
    // Missing field (older clients) counts as ranked.
    ranked: statistics.isRanked === false ? 0 : 1,
    scoreWeight: getScoreWeightForTier(difficultyTier),
    createdAt,
  });
  response.status(201).json({ ok: true });
});

app.get('/api/leaderboard', rateLimit, (request, response) => {
  const query = leaderboardQueries[request.query.category];
  if (!query) {
    response.status(400).json({ error: 'Unknown category' });
    return;
  }
  const limit = clampInteger(request.query.limit || DEFAULT_LIMIT, 1, MAX_LIMIT);
  const rows = query.all(limit);
  const entries = rows.map((row, index) => ({ rank: index + 1, ...row }));
  response.json({ entries });
});

// Unity WebGL builds: pre-compressed files need Content-Encoding and the real type.
app.use(express.static(PUBLIC_DIRECTORY, {
  setHeaders(response, filePath) {
    const isBrotli = filePath.endsWith('.br');
    const isGzip = filePath.endsWith('.gz');
    if (!isBrotli && !isGzip) {
      return;
    }
    response.setHeader('Content-Encoding', isBrotli ? 'br' : 'gzip');
    const uncompressedPath = filePath.slice(0, filePath.lastIndexOf('.'));
    if (uncompressedPath.endsWith('.wasm')) {
      response.setHeader('Content-Type', 'application/wasm');
    } else if (uncompressedPath.endsWith('.js')) {
      response.setHeader('Content-Type', 'application/javascript');
    } else if (uncompressedPath.endsWith('.data')) {
      response.setHeader('Content-Type', 'application/octet-stream');
    }
  },
}));

app.listen(PORT, () => {
  console.log(`Leaderboard server listening on http://localhost:${PORT}`);
  console.log(`Serving WebGL build from ${PUBLIC_DIRECTORY}`);
});
