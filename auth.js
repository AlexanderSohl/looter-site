// Accounts and sessions for Top Down Looter.
// - Email + password accounts (scrypt hashes, Node built-in crypto).
// - Google sign-in via Google Identity Services ID tokens (verified with google-auth-library).
// - Sessions are random tokens in an HttpOnly cookie; only a SHA-256 of the token is stored.
// The game is served from the same origin, so its UnityWebRequests carry the cookie automatically.

'use strict';

const crypto = require('crypto');
const util = require('util');
const { OAuth2Client } = require('google-auth-library');

// ---------- Configuration (TUNING) ----------
const GOOGLE_CLIENT_ID = process.env.GOOGLE_CLIENT_ID || '';
const SESSION_COOKIE_NAME = 'looter_session';
const FORCE_SECURE_COOKIE = process.env.COOKIE_SECURE === '1';
// Per-email login throttle (on top of the per-IP rate limit), so one account cannot be guessed from many IPs.
const MAX_FAILED_LOGINS_PER_EMAIL = 10;
const FAILED_LOGIN_WINDOW_MS = 15 * 60 * 1000;
const TOO_MANY_ATTEMPTS_MESSAGE = 'Too many failed sign-ins for this email. Wait 15 minutes and try again.';
const SESSION_LIFETIME_DAYS = 30;
const SESSION_LIFETIME_MS = SESSION_LIFETIME_DAYS * 24 * 60 * 60 * 1000;
const SESSION_TOKEN_BYTES = 32;
const PASSWORD_SALT_BYTES = 16;
const PASSWORD_KEY_LENGTH = 64;
const MIN_PASSWORD_LENGTH = 8;
const MAX_PASSWORD_LENGTH = 128;
const MAX_EMAIL_LENGTH = 254;
const DEFAULT_NAME_PREFIX = 'Delver';
const DEFAULT_NAME_NUMBER_RANGE = 10000;
const EXPIRED_SESSION_SWEEP_INTERVAL_MS = 60 * 60 * 1000;
// Deliberately loose: the real check is that the user can sign in with it.
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// Same message for "no such email" and "wrong password" so emails can't be probed.
const BAD_LOGIN_MESSAGE = 'Wrong email or password.';

const googleClient = GOOGLE_CLIENT_ID ? new OAuth2Client(GOOGLE_CLIENT_ID) : null;

// ---------- Helpers ----------
// Async scrypt: the sync version would stall every other request for the length of a hash.
const scryptAsync = util.promisify(crypto.scrypt);

async function hashPassword(password) {
  const salt = crypto.randomBytes(PASSWORD_SALT_BYTES);
  const key = await scryptAsync(password, salt, PASSWORD_KEY_LENGTH);
  return `scrypt$${salt.toString('hex')}$${key.toString('hex')}`;
}

async function verifyPassword(password, storedHash) {
  const parts = typeof storedHash === 'string' ? storedHash.split('$') : [];
  if (parts.length !== 3 || parts[0] !== 'scrypt') {
    return false;
  }
  const salt = Buffer.from(parts[1], 'hex');
  const expectedKey = Buffer.from(parts[2], 'hex');
  const actualKey = await scryptAsync(password, salt, expectedKey.length);
  return crypto.timingSafeEqual(actualKey, expectedKey);
}

// A real hash to compare against when the email is unknown, so both paths take the same time.
const DUMMY_PASSWORD_HASH = (() => {
  const salt = crypto.randomBytes(PASSWORD_SALT_BYTES);
  const key = crypto.scryptSync(crypto.randomBytes(PASSWORD_SALT_BYTES), salt, PASSWORD_KEY_LENGTH);
  return `scrypt$${salt.toString('hex')}$${key.toString('hex')}`;
})();

function hashSessionToken(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

function normalizeEmail(rawEmail) {
  return typeof rawEmail === 'string' ? rawEmail.trim().toLowerCase() : '';
}

function readCookie(request, name) {
  const header = request.headers.cookie || '';
  for (const part of header.split(';')) {
    const separatorIndex = part.indexOf('=');
    if (separatorIndex < 0) {
      continue;
    }
    if (part.slice(0, separatorIndex).trim() === name) {
      try {
        return decodeURIComponent(part.slice(separatorIndex + 1).trim());
      } catch (error) {
        return ''; // malformed cookie: treat as signed out (logout can still clear it)
      }
    }
  }
  return '';
}

function buildSessionCookie(request, value, maxAgeSeconds) {
  // Secure over HTTPS (request.secure honours TRUST_PROXY), or always when COOKIE_SECURE=1 is set in
  // production, so a misconfigured proxy cannot drop it. Plain-http localhost testing still works.
  const secureFlag = request.secure || FORCE_SECURE_COOKIE ? '; Secure' : '';
  return `${SESSION_COOKIE_NAME}=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAgeSeconds}${secureFlag}`;
}

// ---------- Module ----------
/**
 * Adds the account tables and the /api/auth + /api/account routes.
 * @param {object} options { app, database, rateLimit, cleanDisplayName, onDisplayNameChanged }
 * @returns {{ requireAccount: Function }} middleware that sets request.account or answers 401.
 */
function installAuth({ app, database, rateLimit, cleanDisplayName, onDisplayNameChanged }) {
  database.exec(`
    CREATE TABLE IF NOT EXISTS accounts (
      id TEXT PRIMARY KEY,
      email TEXT UNIQUE,
      password_hash TEXT,
      google_subject TEXT UNIQUE,
      display_name TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS sessions (
      token_hash TEXT PRIMARY KEY,
      account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      expires_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS sessions_account_index ON sessions(account_id);
  `);

  const findAccountById = database.prepare('SELECT id, email, display_name FROM accounts WHERE id = ?');
  const findAccountByEmail = database.prepare('SELECT id, email, password_hash, google_subject, display_name FROM accounts WHERE email = ?');
  const findAccountByGoogle = database.prepare('SELECT id, email, display_name FROM accounts WHERE google_subject = ?');
  const insertAccount = database.prepare(`
    INSERT INTO accounts (id, email, password_hash, google_subject, display_name, created_at)
    VALUES (@id, @email, @passwordHash, @googleSubject, @displayName, @createdAt)
  `);
  const updateDisplayName = database.prepare('UPDATE accounts SET display_name = ? WHERE id = ?');
  const insertSession = database.prepare('INSERT INTO sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)');
  const findSession = database.prepare('SELECT account_id AS accountId, expires_at AS expiresAt FROM sessions WHERE token_hash = ?');
  const deleteSession = database.prepare('DELETE FROM sessions WHERE token_hash = ?');
  const deleteExpiredSessions = database.prepare('DELETE FROM sessions WHERE expires_at < ?');

  setInterval(() => deleteExpiredSessions.run(Date.now()), EXPIRED_SESSION_SWEEP_INTERVAL_MS).unref();

  function defaultDisplayName() {
    return DEFAULT_NAME_PREFIX + crypto.randomInt(DEFAULT_NAME_NUMBER_RANGE);
  }

  function startSession(request, response, accountId) {
    const token = crypto.randomBytes(SESSION_TOKEN_BYTES).toString('base64url');
    insertSession.run(hashSessionToken(token), accountId, Date.now() + SESSION_LIFETIME_MS);
    response.setHeader('Set-Cookie', buildSessionCookie(request, token, SESSION_LIFETIME_MS / 1000));
  }

  function describeAccount(account) {
    return { accountId: account.id, displayName: account.display_name, email: account.email || '' };
  }

  function getSessionAccount(request) {
    const token = readCookie(request, SESSION_COOKIE_NAME);
    if (!token) {
      return null;
    }
    const session = findSession.get(hashSessionToken(token));
    if (!session || session.expiresAt < Date.now()) {
      return null;
    }
    return findAccountById.get(session.accountId) || null;
  }

  function requireAccount(request, response, next) {
    const account = getSessionAccount(request);
    if (!account) {
      response.status(401).json({ error: 'Sign in on the website to submit runs.' });
      return;
    }
    request.account = account;
    next();
  }

  // Blocks cross-site form posts: HTML forms can't send application/json without a CORS preflight.
  function requireJson(request, response, next) {
    if (!request.is('application/json')) {
      response.status(415).json({ error: 'Expected JSON' });
      return;
    }
    next();
  }

  const jsonBody = require('express').json({ limit: '4kb' });
  const postGuards = [rateLimit, requireJson, jsonBody];

  app.get('/api/config', (request, response) => {
    response.json({ googleClientId: GOOGLE_CLIENT_ID || null });
  });

  app.get('/api/auth/me', (request, response) => {
    const account = getSessionAccount(request);
    if (!account) {
      response.status(401).json({ error: 'Not signed in' });
      return;
    }
    response.json(describeAccount(account));
  });

  // Express 4 does not catch rejected promises: send them to the error handler instead.
  function asyncRoute(handler) {
    return (request, response, next) => Promise.resolve(handler(request, response)).catch(next);
  }

  // email -> times of recent failed sign-ins (in memory; resets on restart like the IP limit).
  const failedLoginTimesByEmail = new Map();
  function getRecentFailedLogins(email) {
    const now = Date.now();
    const recentTimes = (failedLoginTimesByEmail.get(email) || []).filter((time) => now - time < FAILED_LOGIN_WINDOW_MS);
    if (recentTimes.length === 0) {
      failedLoginTimesByEmail.delete(email);
    } else {
      failedLoginTimesByEmail.set(email, recentTimes);
    }
    return recentTimes;
  }
  setInterval(() => {
    for (const email of failedLoginTimesByEmail.keys()) {
      getRecentFailedLogins(email);
    }
  }, FAILED_LOGIN_WINDOW_MS).unref();

  app.post('/api/auth/register', postGuards, asyncRoute(async (request, response) => {
    const body = request.body || {};
    const email = normalizeEmail(body.email);
    const password = typeof body.password === 'string' ? body.password : '';
    const displayName = cleanDisplayName(body.displayName) || defaultDisplayName();

    if (!EMAIL_PATTERN.test(email) || email.length > MAX_EMAIL_LENGTH) {
      response.status(400).json({ error: 'Enter a valid email address.' });
      return;
    }
    if (password.length < MIN_PASSWORD_LENGTH || password.length > MAX_PASSWORD_LENGTH) {
      response.status(400).json({ error: `Password must be ${MIN_PASSWORD_LENGTH}-${MAX_PASSWORD_LENGTH} characters.` });
      return;
    }
    if (findAccountByEmail.get(email)) {
      response.status(409).json({ error: 'An account with this email already exists. Sign in instead.' });
      return;
    }

    const passwordHash = await hashPassword(password);
    // Checked again: another request may have registered this email while we were hashing.
    if (findAccountByEmail.get(email)) {
      response.status(409).json({ error: 'An account with this email already exists. Sign in instead.' });
      return;
    }
    const account = { id: crypto.randomUUID(), email, display_name: displayName };
    insertAccount.run({ id: account.id, email, passwordHash, googleSubject: null, displayName, createdAt: new Date().toISOString() });
    onDisplayNameChanged(account.id, displayName);
    startSession(request, response, account.id);
    response.status(201).json(describeAccount(account));
  }));

  app.post('/api/auth/login', postGuards, asyncRoute(async (request, response) => {
    const body = request.body || {};
    const email = normalizeEmail(body.email);
    const password = typeof body.password === 'string' ? body.password.slice(0, MAX_PASSWORD_LENGTH) : '';
    if (getRecentFailedLogins(email).length >= MAX_FAILED_LOGINS_PER_EMAIL) {
      response.status(429).json({ error: TOO_MANY_ATTEMPTS_MESSAGE });
      return;
    }
    const account = findAccountByEmail.get(email);
    const passwordMatches = await verifyPassword(password, account && account.password_hash ? account.password_hash : DUMMY_PASSWORD_HASH);
    if (!account || !account.password_hash || !passwordMatches) {
      const failedTimes = getRecentFailedLogins(email);
      failedTimes.push(Date.now());
      failedLoginTimesByEmail.set(email, failedTimes);
      response.status(401).json({ error: BAD_LOGIN_MESSAGE });
      return;
    }
    failedLoginTimesByEmail.delete(email);
    startSession(request, response, account.id);
    response.json(describeAccount(account));
  }));

  app.post('/api/auth/google', postGuards, async (request, response) => {
    if (!googleClient) {
      response.status(503).json({ error: 'Google sign-in is not configured on this server.' });
      return;
    }
    let payload;
    try {
      const ticket = await googleClient.verifyIdToken({ idToken: String((request.body || {}).credential || ''), audience: GOOGLE_CLIENT_ID });
      payload = ticket.getPayload();
    } catch (error) {
      response.status(401).json({ error: 'Google sign-in failed. Try again.' });
      return;
    }

    // Express 4 does not catch errors thrown after an await, so guard the database work here.
    try {
      signInWithGooglePayload(request, response, payload);
    } catch (error) {
      console.error(error);
      response.status(500).json({ error: 'Sign-in failed on the server.' });
    }
  });

  function signInWithGooglePayload(request, response, payload) {
    let account = findAccountByGoogle.get(payload.sub);
    if (!account) {
      const email = payload.email_verified ? normalizeEmail(payload.email) : '';
      // No automatic linking to a password account: its email was never verified, so
      // linking would let someone pre-register a victim's address and share their account.
      if (email && findAccountByEmail.get(email)) {
        response.status(409).json({ error: 'This email already has a password account. Sign in with your password.' });
        return;
      }
      const displayName = cleanDisplayName(payload.given_name || payload.name) || defaultDisplayName();
      account = { id: crypto.randomUUID(), email: email || null, display_name: displayName };
      insertAccount.run({ id: account.id, email: account.email, passwordHash: null, googleSubject: payload.sub, displayName, createdAt: new Date().toISOString() });
      onDisplayNameChanged(account.id, displayName);
    }
    startSession(request, response, account.id);
    response.json(describeAccount(account));
  }

  app.post('/api/auth/logout', postGuards, (request, response) => {
    const token = readCookie(request, SESSION_COOKIE_NAME);
    if (token) {
      deleteSession.run(hashSessionToken(token));
    }
    response.setHeader('Set-Cookie', buildSessionCookie(request, '', 0));
    response.json({ ok: true });
  });

  app.post('/api/account/name', postGuards, requireAccount, (request, response) => {
    const displayName = cleanDisplayName((request.body || {}).displayName);
    if (!displayName) {
      response.status(400).json({ error: 'Names use letters, numbers, spaces, _ and -.' });
      return;
    }
    updateDisplayName.run(displayName, request.account.id);
    onDisplayNameChanged(request.account.id, displayName);
    response.json(describeAccount({ ...request.account, display_name: displayName }));
  });

  return { requireAccount, requireJson };
}

module.exports = { installAuth };
