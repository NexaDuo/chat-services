import type { FastifyInstance } from "fastify";

// In-process because middleware runs as a single instance: the handoff route and
// Dify flush share this registry. Scope by app and account/conversation, and retain
// only in-flight calls. Finally cleanup plus a hard cap bounds even hung calls;
// over capacity, turns fail closed (no handoff exception to the ownership check).
const MAX_TRACKED_TURNS = 1000;
const registries = new WeakMap<FastifyInstance, Map<string, DifyTurn>>();

type DifyTurn = {
  handedOff: boolean;
  markHandedOff(): void;
  finish(): void;
};

function key(accountId: string, conversationId: number | string): string {
  return JSON.stringify([accountId, String(conversationId)]);
}

export function beginDifyTurn(
  app: FastifyInstance,
  accountId: string,
  conversationId: number | string,
): DifyTurn {
  let registry = registries.get(app);
  if (!registry) {
    registry = new Map();
    registries.set(app, registry);
  }
  const id = key(accountId, conversationId);
  const turn: DifyTurn = {
    handedOff: false,
    markHandedOff() {
      if (registry.get(id) === turn) turn.handedOff = true;
    },
    finish() {
      if (registry.get(id) === turn) registry.delete(id);
    },
  };
  if (registry.size < MAX_TRACKED_TURNS) registry.set(id, turn);
  return turn;
}

export function getInFlightDifyTurn(
  app: FastifyInstance,
  accountId: string,
  conversationId: number | string,
): DifyTurn | undefined {
  return registries.get(app)?.get(key(accountId, conversationId));
}
