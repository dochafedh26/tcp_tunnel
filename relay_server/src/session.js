/**
 * session.js — RelaySession: pairs Flutter clients with a Dart agent and bridges traffic.
 * Fully supports multiplexing multiple concurrent clients to the same agent.
 */

'use strict';

const { parseMessage } = require('./protocol');
const { v4: uuidv4 } = require('uuid');

class RelaySession {
  /**
   * @param {string} sessionId
   * @param {object} logger
   */
  constructor(sessionId, logger) {
    this.sessionId = sessionId;
    this.logger = logger;
    this.clients = new Set();
    this.channelClients = new Map();
    this.requestClients = new Map();
    this.agentWs = null;
    this.channelCount = 0;
    this.bytesRelayed = 0;
    this.createdAt = new Date();
    this.token = null;
  }

  /**
   * Attach a Flutter client WebSocket.
   * Multiple clients are allowed simultaneously.
   * @param {import('ws').WebSocket} ws
   * @param {string} [clientId]
   */
  setClient(ws, clientId) {
    const formattedClientId = clientId || `Unknown-${uuidv4()}`;

    // Clean up any stale client socket with the exact same clientId
    for (const oldWs of this.clients) {
      if (oldWs._clientId === formattedClientId) {
        this.logger.info(`[${this.sessionId}] Replacing connection for client "${formattedClientId}"`);
        oldWs.terminate();
        this.clients.delete(oldWs);
      }
    }

    ws._clientId = formattedClientId;
    this.clients.add(ws);
    this.logger.info(`[${this.sessionId}] Client "${ws._clientId}" connected (Active clients: ${this.clients.size})`);

    // Notify client auth succeeded
    ws.send(JSON.stringify({ type: 'auth_ok', role: 'client' }));

    ws.on('message', (data, isBinary) => this._handleClientMessage(ws, data, isBinary));
    ws.on('close', () => {
      if (this.clients.has(ws)) {
        this.logger.info(`[${this.sessionId}] Client "${ws._clientId}" disconnected`);
        this.clients.delete(ws);

        // Remove any channel/request bindings associated with this client
        for (const [chanId, client] of this.channelClients.entries()) {
          if (client === ws) this.channelClients.delete(chanId);
        }
        for (const [reqId, client] of this.requestClients.entries()) {
          if (client === ws) this.requestClients.delete(reqId);
        }

        this._handleClose('client');
      }
    });
    ws.on('error', (err) => {
      this.logger.error(`[${this.sessionId}] Client "${ws._clientId}" WS error: ${err.message}`);
    });

    // If agent is already connected, notify the new client
    if (this.agentWs) {
      ws.send(JSON.stringify({ type: 'peer_connected' }));
      try {
        this.agentWs.send(JSON.stringify({ type: 'peer_connected' }));
      } catch (e) {
        this.logger.warn(`[${this.sessionId}] Error sending peer_connected to agent: ${e.message}`);
      }
    }
  }

  /**
   * Attach the Dart agent WebSocket.
   * @param {import('ws').WebSocket} ws
   * @param {string} [agentName]
   */
  setAgent(ws, agentName) {
    if (this.agentWs) {
      this.logger.warn(`[${this.sessionId}] Replacing existing agent connection`);
      this.agentWs.terminate();
    }
    this.agentWs = ws;
    this.agentName = agentName || 'Unknown Agent';
    this.logger.info(`[${this.sessionId}] Agent "${this.agentName}" connected`);

    // Notify agent auth succeeded
    ws.send(JSON.stringify({ type: 'auth_ok', role: 'agent' }));

    ws.on('message', (data, isBinary) => this._handleAgentMessage(ws, data, isBinary));
    ws.on('close', () => {
      if (this.agentWs === ws) {
        this.logger.info(`[${this.sessionId}] Agent "${this.agentName}" disconnected`);
        this.agentWs = null;
        this._handleClose('agent');
      }
    });
    ws.on('error', (err) => {
      this.logger.error(`[${this.sessionId}] Agent "${this.agentName}" WS error: ${err.message}`);
    });

    // If clients are already connected, notify the agent and all clients
    if (this.clients.size > 0) {
      this._notifyPeerConnected('agent');
    }
  }

  /**
   * Notify connected sides that the session peers are ready.
   * @param {'client'|'agent'} newRole - the role that just connected
   */
  _notifyPeerConnected(newRole) {
    this.logger.info(`[${this.sessionId}] Agent and at least one client connected — tunnel ready`);
    try {
      if (newRole === 'agent') {
        for (const client of this.clients) {
          if (client.readyState === 1) {
            client.send(JSON.stringify({ type: 'peer_connected' }));
          }
        }
      }
      this.agentWs?.send(JSON.stringify({ type: 'peer_connected' }));
    } catch (e) {
      this.logger.warn(`[${this.sessionId}] Error sending peer_connected: ${e.message}`);
    }
  }

  /**
   * Forward a message from a specific client to the agent.
   */
  _handleClientMessage(ws, data, isBinary) {
    if (!isBinary) {
      try {
        const msg = JSON.parse(data.toString());
        if (msg.type === 'ping') {
          ws._lastPing = Date.now();
          ws.send(JSON.stringify({ type: 'pong' }));
          return;
        }
        if (msg.channelId) {
          this.channelClients.set(msg.channelId, ws);
        }
        if (msg.requestId) {
          this.requestClients.set(msg.requestId, ws);
        }
      } catch (e) {}
    } else {
      const parsed = parseMessage(data);
      if (parsed && parsed.type === 'data' && parsed.channelId) {
        this.channelClients.set(parsed.channelId, ws);
      }
    }

    if (!this.agentWs || this.agentWs.readyState !== 1 /* OPEN */) {
      this.logger.warn(`[${this.sessionId}] Client sent data but agent not connected`);
      return;
    }
    try {
      this.agentWs.send(data, { binary: isBinary });
      if (isBinary && Buffer.isBuffer(data)) {
        this.bytesRelayed += data.length;
      }
      // Track channel open/close from control messages
      if (!isBinary) {
        this._trackChannelStats(data.toString());
      }
    } catch (e) {
      this.logger.error(`[${this.sessionId}] Error forwarding client→agent: ${e.message}`);
    }
  }

  /**
   * Forward a message from the agent to the appropriate client (multiplexed).
   */
  _handleAgentMessage(ws, data, isBinary) {
    if (!isBinary) {
      try {
        const msg = JSON.parse(data.toString());
        if (msg.type === 'ping') {
          ws._lastPing = Date.now();
          ws.send(JSON.stringify({ type: 'pong' }));
          return;
        }
      } catch (e) {}
    }

    // Binary Data Frames routing
    if (isBinary) {
      const parsed = parseMessage(data);
      if (parsed && parsed.type === 'data' && parsed.channelId) {
        const targetWs = this.channelClients.get(parsed.channelId);
        if (targetWs && targetWs.readyState === 1) {
          targetWs.send(data, { binary: isBinary });
          this.bytesRelayed += data.length;
        }
        return;
      }
    }

    // JSON Control Messages routing
    try {
      const msg = JSON.parse(data.toString());
      let targetWs = null;

      if (msg.channelId) {
        targetWs = this.channelClients.get(msg.channelId);
        // Delete mapping on channel teardown to free memory
        if (msg.type === 'close' || msg.type === 'error') {
          this.channelClients.delete(msg.channelId);
        }
      } else if (msg.requestId) {
        targetWs = this.requestClients.get(msg.requestId);
        this.requestClients.delete(msg.requestId);
      }

      if (targetWs && targetWs.readyState === 1) {
        targetWs.send(data, { binary: isBinary });
      } else {
        // Fallback: broadcast JSON responses to all clients
        for (const client of this.clients) {
          if (client.readyState === 1) {
            client.send(data, { binary: isBinary });
          }
        }
      }
    } catch (e) {
      // General fallback: broadcast to all clients if parsing fails
      for (const client of this.clients) {
        if (client.readyState === 1) {
          client.send(data, { binary: isBinary });
        }
      }
    }
  }

  /**
   * Track open/opened/close messages to count active channels.
   */
  _trackChannelStats(text) {
    try {
      const msg = JSON.parse(text);
      if (msg.type === 'open') this.channelCount++;
      if (msg.type === 'close' || msg.type === 'error') {
        this.channelCount = Math.max(0, this.channelCount - 1);
      }
    } catch { /* ignore parse errors */ }
  }

  /**
   * Handle one side disconnecting.
   * @param {'client'|'agent'} role
   */
  _handleClose(role) {
    if (role === 'client') {
      if (this.clients.size === 0) {
        this.agentWs?.send(JSON.stringify({ type: 'peer_disconnected', role }));
        this.channelCount = 0;
      }
    } else {
      // Notify all connected clients that the agent has left
      for (const client of this.clients) {
        if (client.readyState === 1) {
          client.send(JSON.stringify({ type: 'peer_disconnected', role }));
        }
      }
      this.channelCount = 0;
    }
  }

  /**
   * Return session stats.
   */
  getStats() {
    const uptimeMs = Date.now() - this.createdAt.getTime();
    return {
      sessionId: this.sessionId,
      agentName: this.agentName || 'Unknown Agent',
      clientId: [...this.clients].map(c => c._clientId).join(', ') || 'No Client',
      hasClient: this.clients.size > 0,
      hasAgent: this.agentWs?.readyState === 1,
      channelCount: this.channelCount,
      bytesRelayed: this.bytesRelayed,
      uptimeSeconds: Math.floor(uptimeMs / 1000),
      token: this.token || '',
    };
  }
}

module.exports = RelaySession;
