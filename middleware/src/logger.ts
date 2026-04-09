/**
 * Structural logger interface — compatible with both `pino.Logger` and
 * Fastify's `FastifyBaseLogger`. We keep it narrow on purpose so clients
 * can accept either without version skew between pino major versions.
 */
export interface Logger {
  trace: LogFn;
  debug: LogFn;
  info: LogFn;
  warn: LogFn;
  error: LogFn;
  fatal: LogFn;
}

interface LogFn {
  (msg: string, ...args: unknown[]): void;
  (obj: unknown, msg?: string, ...args: unknown[]): void;
}

/**
 * Produces the Fastify `logger` option value (a pino config object) from the
 * app config. Letting Fastify instantiate pino itself avoids cross-version
 * type conflicts when we'd otherwise pass `loggerInstance: myPino`.
 */
export function buildFastifyLoggerConfig(level: string): object {
  const isProduction = process.env.NODE_ENV === "production";
  return {
    level,
    base: { service: "nexaduo-middleware" },
    timestamp: () => `,"time":"${new Date().toISOString()}"`,
    ...(isProduction
      ? {}
      : {
          transport: {
            target: "pino-pretty",
            options: {
              colorize: true,
              translateTime: "HH:MM:ss.l",
              ignore: "pid,hostname,service",
            },
          },
        }),
  };
}
