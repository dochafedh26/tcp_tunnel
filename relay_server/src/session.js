/**
 * session.js — RelaySession: pairs a Flutter client with a Dart agent and bridges traffic.
 */

'use strict';

const { parseMessage } = require('./protocol');

class RelaySession {
  /**
   * @param {string} sessionId
   * @param {object} logger
   */
  constructor(sessionId, logger) {
    this.sessionId = sessionId;
    this.logger = logger;
    this.clientWs = null;
    this.agentWs = null;
    this.channelCount = 0;
    this.bytesRelayed = 0;
    this.createdAt = new Date();
  }

  /**
   * Attach the Flutter client WebSocket.
   * @param {import('ws').WebSocket} ws
   */
  setClient(ws) {
    if (this.clientWs) {
      this.logger.warn(`[${this.sessionId}] Replacing existing client connection`);
      this.clientWs.terminate();
    }
    this.clientWs = ws;
    this.logger.info(`[${this.sessionId}] Client connected`);

    // Notify client auth succeeded
    ws.send(JSON.stringify({ type: 'auth_ok', role: 'client' }));

    ws.on('message', (data, isBinary) => this._handleClientMessage(data, isBinary));
    ws.on('close', () => {
      this.logger.info(`[${this.sessionId}] Client disconnected`);
      this.clientWs = null;
      this._handleClose('client');
    });
    ws.on('error', (err) => {
      this.logger.error(`[${this.sessionId}] Client WS error: ${err.message}`);
    });

    // If agent is already connected, notify both sides
    if (this.agentWs) {
      this._notifyPeerConnected('client');
    }
  }

  /**
   * Attach the Dart agent WebSocket.
   * @param {import('ws').WebSocket} ws
   */
  setAgent(ws) {
    if (this.agentWs) {
      this.logger.warn(`[${this.sessionId}] Replacing existing agent connection`);
      this.agentWs.terminate();
    }
    this.agentWs = ws;
    this.logger.info(`[${this.sessionId}] Agent connected`);

    // Notify agent auth succeeded
    ws.send(JSON.stringify({ type: 'auth_ok', role: 'agent' }));

    ws.on('message', (data, isBinary) => this._handleAgentMessage(data, isBinary));
    ws.on('close', () => {
      this.logger.info(`[${this.sessionId}] Agent disconnected`);
      this.agentWs = null;
      this._handleClose('agent');
    });
    ws.on('error', (err) => {
      this.logger.error(`[${this.sessionId}] Agent WS error: ${err.message}`);
    });

    // If client is already connected, notify both sides
    if (this.clientWs) {
      this._notifyPeerConnected('agent');
    }
  }

  /**
   * Notify both sides that the full session is ready.
   * @param {'client'|'agent'} newRole - the role that just connected
   */
  _notifyPeerConnected(newRole) {
    this.logger.info(`[${this.sessionId}] Both client and agent connected — tunnel ready`);
    try {
      this.clientWs?.send(JSON.stringify({ type: 'peer_connected' }));
      this.agentWs?.send(JSON.stringify({ type: 'peer_connected' }));
    } catch (e) {
      this.logger.warn(`[${this.sessionId}] Error sending peer_connected: ${e.message}`);
    }
  }

  /**
   * Forward a message from the client to the agent.
   */
  _handleClientMessage(data, isBinary) {
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
   * Forward a message from the agent to the client.
   */
  _handleAgentMessage(data, isBinary) {
    if (!this.clientWs || this.clientWs.readyState !== 1 /* OPEN */) {
      this.logger.warn(`[${this.sessionId}] Agent sent data but client not connected`);
      return;
    }
    try {
      this.clientWs.send(data, { binary: isBinary });
      if (isBinary && Buffer.isBuffer(data)) {
        this.bytesRelayed += data.length;
      }
      // Track channel confirmations
      if (!isBinary) {
        this._trackChannelStats(data.toString());
      }
    } catch (e) {
      this.logger.error(`[${this.sessionId}] Error forwarding agent→client: ${e.message}`);
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
    // Notify the other side
    const other = role === 'client' ? this.agentWs : this.clientWs;
    if (other && other.readyState === 1) {
      try {
        other.send(JSON.stringify({ type: 'peer_disconnected', role }));
      } catch { /* ignore */ }
    }
    this.channelCount = 0;
  }

  /**
   * Return session stats.
   */
  getStats() {
    const uptimeMs = Date.now() - this.createdAt.getTime();
    return {
      sessionId: this.sessionId,
      hasClient: this.clientWs?.readyState === 1,
      hasAgent: this.agentWs?.readyState === 1,
      channelCount: this.channelCount,
      bytesRelayed: this.bytesRelayed,
      uptimeSeconds: Math.floor(uptimeMs / 1000),
    };
  }
}

module.exports = RelaySession;
