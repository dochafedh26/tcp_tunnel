'use strict';

require('dotenv').config();
const pkg = require('../package.json');

const http = require('http');
const { WebSocketServer } = require('ws');
const { v4: uuidv4 } = require('uuid');
const RelaySession = require('./session');
const logger = require('./logger');
const { parseMessage } = require('./protocol');

// Phusion Passenger (cPanel Node.js App Manager) passes a socket path in process.env.PORT instead of a number.
// We must parse it as an integer only if it's a numeric string, otherwise use the raw value (for socket path).
const rawPort = process.env.PORT || '8080';
const PORT = /^\d+$/.test(rawPort) ? parseInt(rawPort, 10) : rawPort;
const AUTH_TOKEN = process.env.AUTH_TOKEN || 'changeme';
const AUTH_TIMEOUT_MS = 10_000;

// sessions: Map<token, RelaySession>
// (token acts as session key — client and agent sharing a token belong to same session)
const sessions = new Map();

// ─── HTTP Server ─────────────────────────────────────────────────────────────
const server = http.createServer((req, res) => {
  // Set CORS headers for all incoming requests
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  // Handle OPTIONS preflight requests
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  if (req.url === '/health') {
    const stats = [...sessions.values()].map((s) => s.getStats());
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', sessions: stats, uptime: process.uptime() }));
    return;
  }
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('TCP Tunnel Relay Server — OK\n');
});

// ─── WebSocket Server ─────────────────────────────────────────────────────────
const wss = new WebSocketServer({ server });

// ─── Heartbeat ────────────────────────────────────────────────────────────────
// Railway's reverse proxy drops idle WebSocket connections after ~60s.
// Ping all connected clients every 25s to keep the connection alive.
// Note: We use application-level pings rather than WebSocket-level ping/pong
// because some cloud proxies (Render free tier) don't forward WebSocket control frames.
const HEARTBEAT_INTERVAL_MS = 30_000;
const HEARTBEAT_TIMEOUT_MS = 90_000;
const heartbeatInterval = setInterval(() => {
  const now = Date.now();
  wss.clients.forEach((ws) => {
    const lastPing = ws._lastPing || now;
    if (now - lastPing > HEARTBEAT_TIMEOUT_MS) {
      logger.warn('Terminating unresponsive WebSocket client (no application-level ping for ' + (now - lastPing) + 'ms)');
      ws.terminate();
    }
  });
}, HEARTBEAT_INTERVAL_MS);

wss.on('close', () => clearInterval(heartbeatInterval));

wss.on('connection', (ws, req) => {
  ws._lastPing = Date.now();
  ws.on('pong', () => { ws._lastPing = Date.now(); });
  const clientIp = (req.headers['x-forwarded-for'] || req.socket.remoteAddress || 'unknown')
    .split(',')[0]
    .trim();
  logger.info(`New WS connection from ${clientIp}`);

  // ── Step 1: Wait for auth message ──────────────────────────────────────────
  let authenticated = false;

  const authTimeout = setTimeout(() => {
    if (!authenticated) {
      logger.warn(`Auth timeout from ${clientIp}`);
      ws.send(JSON.stringify({ type: 'auth_error', message: 'Authentication timeout' }));
      ws.terminate();
    }
  }, AUTH_TIMEOUT_MS);

  ws.once('message', (rawData) => {
    clearTimeout(authTimeout);

    // Parse auth message
    let msg;
    try {
      msg = parseMessage(rawData.toString());
    } catch (e) {
      logger.warn(`Bad auth message from ${clientIp}: ${e.message}`);
      ws.send(JSON.stringify({ type: 'auth_error', message: 'Malformed auth message' }));
      ws.terminate();
      return;
    }

    // Validate auth
    if (!msg || msg.type !== 'auth') {
      logger.warn(`Expected auth from ${clientIp}, got: ${msg?.type}`);
      ws.send(JSON.stringify({ type: 'auth_error', message: 'First message must be auth' }));
      ws.terminate();
      return;
    }

    const validTokens = AUTH_TOKEN.split(',').map(t => t.trim());
    if (AUTH_TOKEN !== '*' && !validTokens.includes(msg.token)) {
      logger.warn(`Invalid token from ${clientIp}`);
      ws.send(JSON.stringify({ type: 'auth_error', message: 'Invalid token' }));
      ws.terminate();
      return;
    }

    const role = msg.role;
    if (role !== 'client' && role !== 'agent') {
      logger.warn(`Invalid role "${role}" from ${clientIp}`);
      ws.send(JSON.stringify({ type: 'auth_error', message: 'Role must be client or agent' }));
      ws.terminate();
      return;
    }

    authenticated = true;
    logger.info(`Authenticated as ${role} from ${clientIp}`);

    // ── Step 2: Get or create session ─────────────────────────────────────────
    // Using token as session key allows client+agent to be paired automatically
    const sessionKey = msg.token;
    if (!sessions.has(sessionKey)) {
      const newSession = new RelaySession(uuidv4(), logger);
      newSession.token = sessionKey;
      sessions.set(sessionKey, newSession);
    }
    const session = sessions.get(sessionKey);

    // ── Step 3: Attach to session ─────────────────────────────────────────────
    if (role === 'client') {
      session.setClient(ws, msg.clientId);
    } else {
      session.setAgent(ws, msg.name);
    }

    // ── Step 4: Cleanup on disconnect ─────────────────────────────────────────
    ws.on('close', () => {
      // Remove session when both sides are gone
      if (!session.clientWs && !session.agentWs) {
        sessions.delete(sessionKey);
        logger.info(`Session ${session.sessionId} cleaned up`);
      }
    });
  });

  ws.on('error', (err) => {
    clearTimeout(authTimeout);
    logger.error(`WS error from ${clientIp}: ${err.message}`);
  });
});

// ─── Start ────────────────────────────────────────────────────────────────────
const rawVersion = process.env.RAILWAY_GIT_TAG || process.env.VERSION || pkg.version || '1.0.0';
const VERSION = rawVersion.startsWith('v') ? rawVersion.substring(1) : rawVersion;

server.listen(PORT, () => {
  logger.info('══════════════════════════════════════════');
  logger.info(` TCP Tunnel Relay Server v${VERSION}`);
  logger.info('══════════════════════════════════════════');
  logger.info(`Listening on port ${PORT}`);
  logger.info(`Auth token : ${AUTH_TOKEN === '*' ? 'ANY (Wildcard mode enabled)' : (AUTH_TOKEN === 'changeme' ? 'changeme [⚠ CHANGE IN PRODUCTION]' : '[configured]')}`);
  logger.info(`Health URL : http://localhost:${PORT}/health`);
  logger.info('══════════════════════════════════════════');
});

// ─── Graceful shutdown ────────────────────────────────────────────────────────
process.on('SIGTERM', () => {
  logger.info('SIGTERM received — shutting down gracefully');
  wss.close(() => {
    server.close(() => {
      logger.info('Server closed');
      process.exit(0);
    });
  });
});
