/**
 * logger.js — Simple timestamped logger for TCP Tunnel Relay
 */

const LOG_LEVEL = (process.env.LOG_LEVEL || 'info').toLowerCase();
const LEVELS = { debug: 0, info: 1, warn: 2, error: 3 };
const currentLevel = LEVELS[LOG_LEVEL] ?? 1;

function format(level, message) {
  return `[${new Date().toISOString()}] [${level.toUpperCase().padEnd(5)}] ${message}`;
}

const logger = {
  debug: (msg) => { if (currentLevel <= 0) console.debug(format('debug', msg)); },
  info:  (msg) => { if (currentLevel <= 1) console.log(format('info',  msg)); },
  warn:  (msg) => { if (currentLevel <= 2) console.warn(format('warn',  msg)); },
  error: (msg) => { if (currentLevel <= 3) console.error(format('error', msg)); },
};

module.exports = logger;
