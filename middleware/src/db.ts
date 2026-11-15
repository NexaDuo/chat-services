import pg from "pg";
import { buildPoolOptions, type AppConfig } from "./config.js";

/**
 * The single place a pg.Pool is created (issue #299 REV-6): bounded timeouts
 * plus an error listener, so an idle-client error cannot crash the process.
 * `connectionString` overrides the middleware DB URL (e.g. the Dify DB).
 */
export function createPool(
  config: AppConfig,
  onError: (err: Error) => void,
  connectionString?: string,
): pg.Pool {
  const PoolClass = pg.Pool || (pg as any).default?.Pool;
  const pool: pg.Pool = new PoolClass(buildPoolOptions(config, connectionString));
  pool.on("error", onError);
  return pool;
}
