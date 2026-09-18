"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const node_path_1 = __importDefault(require("node:path"));
const Env_1 = __importDefault(global[Symbol.for('ioc.use')]("Adonis/Core/Env"));
const SQLITE_JOURNAL_MODE_VALUES = new Set([
    'DELETE',
    'TRUNCATE',
    'PERSIST',
    'MEMORY',
    'WAL',
    'OFF',
]);
const SQLITE_SYNCHRONOUS_VALUES = new Set(['OFF', 'NORMAL', 'FULL', 'EXTRA']);
const SQLITE_BUSY_TIMEOUT_DEFAULT = 5000;
const SQLITE_JOURNAL_MODE_DEFAULT = 'WAL';
const SQLITE_SYNCHRONOUS_DEFAULT = 'FULL';
function getSqlitePragmaValue(envName, defaultValue, allowedValues) {
    const configuredValue = Env_1.default.get(envName, defaultValue).trim().toUpperCase();
    if (!allowedValues.has(configuredValue)) {
        return defaultValue;
    }
    return configuredValue;
}
const sqliteBusyTimeoutEnv = Env_1.default.get('DB_BUSY_TIMEOUT', SQLITE_BUSY_TIMEOUT_DEFAULT.toString());
const sqliteBusyTimeoutParsed = Number.parseInt(sqliteBusyTimeoutEnv, 10);
const sqliteBusyTimeout = Number.isFinite(sqliteBusyTimeoutParsed) && sqliteBusyTimeoutParsed > 0
    ? sqliteBusyTimeoutParsed
    : SQLITE_BUSY_TIMEOUT_DEFAULT;
const sqliteJournalMode = getSqlitePragmaValue('DB_SQLITE_JOURNAL_MODE', SQLITE_JOURNAL_MODE_DEFAULT, SQLITE_JOURNAL_MODE_VALUES);
const sqliteSynchronous = getSqlitePragmaValue('DB_SQLITE_SYNCHRONOUS', SQLITE_SYNCHRONOUS_DEFAULT, SQLITE_SYNCHRONOUS_VALUES);
function configureSqliteConnection(conn, cb) {
    return conn.run('PRAGMA foreign_keys = ON', (error) => {
        if (error) {
            cb(error, conn);
            return;
        }
        conn.run(`PRAGMA journal_mode = ${sqliteJournalMode}`, (journalModeError) => {
            if (journalModeError) {
                cb(journalModeError, conn);
                return;
            }
            conn.run(`PRAGMA synchronous = ${sqliteSynchronous}`, (synchronousError) => {
                if (synchronousError) {
                    cb(synchronousError, conn);
                    return;
                }
                conn.run(`PRAGMA busy_timeout = ${sqliteBusyTimeout}`, (busyTimeoutError) => cb(busyTimeoutError, conn));
            });
        });
    });
}
const databaseConfig = {
    connection: 'mysql',
    connections: {
        sqlite: {
            client: 'sqlite',
            connection: {
                filename: node_path_1.default.join(Env_1.default.get('DATA_DIR', 'data'), `${Env_1.default.get('DB_DATABASE', 'ferdium')}.sqlite`),
            },
            pool: {
                afterCreate: configureSqliteConnection,
                min: 1,
                max: 1,
            },
            migrations: {
                naturalSort: true,
            },
            useNullAsDefault: true,
            healthCheck: false,
            debug: Env_1.default.get('DB_DEBUG', false),
        },
        mysql: {
            client: 'mysql',
            connection: {
                host: Env_1.default.get('DB_HOST', 'localhost'),
                port: Env_1.default.get('DB_PORT', ''),
                user: Env_1.default.get('DB_USER', 'root'),
                password: Env_1.default.get('DB_PASSWORD', ''),
                database: Env_1.default.get('DB_DATABASE', 'ferdium'),
                ssl: Env_1.default.get('DB_SSL', false),
            },
            migrations: {
                naturalSort: true,
            },
            healthCheck: false,
            debug: Env_1.default.get('DB_DEBUG', false),
        },
        pg: {
            client: 'pg',
            connection: {
                host: Env_1.default.get('DB_HOST', 'localhost'),
                port: Env_1.default.get('DB_PORT', ''),
                user: Env_1.default.get('DB_USER', 'root'),
                password: Env_1.default.get('DB_PASSWORD', ''),
                database: Env_1.default.get('DB_DATABASE', 'ferdium'),
                ssl: Env_1.default.get('DB_SSL', false),
            },
            migrations: {
                naturalSort: true,
            },
            healthCheck: false,
            debug: Env_1.default.get('DB_DEBUG', false),
        },
    },
};
exports.default = databaseConfig;
