'use strict';

require('dotenv').config();

const http = require('http');
const { WebSocketServer } = require('ws');
const { v4: uuidv4 } = require('uuid');
const RelaySession = require('./session');
const logger = require('./logger');
const { parseMessage } = require('./protocol');

const PORT = parseInt(process.env.PORT || '8080', 10);
const AUTH_TOKEN = process.env.AUTH_TOKEN || 'changeme';
const AUTH_TIMEOUT_MS = 10_000;

// sessions: Map<token, RelaySession>
// (token acts as session key — client and agent sharing a token belong to same session)
const sessions = new Map();

// ─── HTTP Server ─────────────────────────────────────────────────────────────
const server = http.createServer((req, res) => {
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

wss.on('connection', (ws, req) => {
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

    if (msg.token !== AUTH_TOKEN) {
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
      sessions.set(sessionKey, new RelaySession(uuidv4(), logger));
    }
    const session = sessions.get(sessionKey);

    // ── Step 3: Attach to session ─────────────────────────────────────────────
    if (role === 'client') {
      session.setClient(ws);
    } else {
      session.setAgent(ws);
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
server.listen(PORT, () => {
  logger.info('══════════════════════════════════════════');
  logger.info(' TCP Tunnel Relay Server');
  logger.info('══════════════════════════════════════════');
  logger.info(`Listening on port ${PORT}`);
  logger.info(`Auth token : ${AUTH_TOKEN === 'changeme' ? 'changeme [⚠ CHANGE IN PRODUCTION]' : '[configured]'}`);
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
