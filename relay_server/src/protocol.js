/**
 * protocol.js — Wire protocol helpers for TCP Tunnel Relay
 *
 * Binary data frame layout:
 *   [0x01 (1 byte)] [channelId ASCII UUID (36 bytes)] [TCP payload (N bytes)]
 *   Total header = 37 bytes
 *
 * Control messages are UTF-8 JSON text frames.
 */

const FRAME_TYPE_DATA = 0x01;
const CHANNEL_ID_LENGTH = 36;
const HEADER_LENGTH = 37; // 1 + 36

/**
 * Parse an incoming WebSocket message.
 * @param {Buffer|string} data
 * @returns {{ type: string, ...} | { type: 'data', channelId: string, payload: Buffer } | null}
 */
function parseMessage(data) {
  if (Buffer.isBuffer(data)) {
    if (data.length >= HEADER_LENGTH && data[0] === FRAME_TYPE_DATA) {
      return {
        type: 'data',
        channelId: data.slice(1, HEADER_LENGTH).toString('ascii'),
        payload: data.slice(HEADER_LENGTH),
      };
    }
    // Try parse as JSON (text sent as Buffer)
    try {
      return JSON.parse(data.toString('utf8'));
    } catch {
      return null;
    }
  }
  if (typeof data === 'string') {
    try {
      return JSON.parse(data);
    } catch {
      return null;
    }
  }
  return null;
}

/**
 * Encode a binary data frame.
 * @param {string} channelId - 36-char UUID string
 * @param {Buffer} payload
 * @returns {Buffer}
 */
function encodeDataFrame(channelId, payload) {
  const channelBytes = Buffer.from(channelId, 'ascii'); // 36 bytes
  const frame = Buffer.allocUnsafe(HEADER_LENGTH + payload.length);
  frame[0] = FRAME_TYPE_DATA;
  channelBytes.copy(frame, 1);
  payload.copy(frame, HEADER_LENGTH);
  return frame;
}

/**
 * Returns true if data is a binary data frame.
 * @param {Buffer|string} data
 */
function isBinaryFrame(data) {
  return Buffer.isBuffer(data) && data.length >= HEADER_LENGTH && data[0] === FRAME_TYPE_DATA;
}

/**
 * Returns true if data is a JSON text control message.
 */
function isControlMessage(data) {
  return typeof data === 'string';
}

module.exports = { FRAME_TYPE_DATA, CHANNEL_ID_LENGTH, HEADER_LENGTH, parseMessage, encodeDataFrame, isBinaryFrame, isControlMessage };
