import Fastify from "fastify";
import { describe, expect, it } from "vitest";
import { beginDifyTurn, getInFlightDifyTurn } from "./in-turn-handoff.js";

describe("in-turn handoff registry", () => {
  it("isolates accounts/apps and ignores delayed handoffs after a turn settles", async () => {
    const app = Fastify();
    const otherApp = Fastify();
    const first = beginDifyTurn(app, "1", 8);
    expect(getInFlightDifyTurn(app, "1", "8")).toBe(first);
    expect(getInFlightDifyTurn(app, "2", 8)).toBeUndefined();
    expect(getInFlightDifyTurn(otherApp, "1", 8)).toBeUndefined();
    first.finish();
    const next = beginDifyTurn(app, "1", 8);
    first.markHandedOff();
    first.finish();
    expect(first.handedOff).toBe(false);
    expect(next.handedOff).toBe(false);
    expect(getInFlightDifyTurn(app, "1", 8)).toBe(next);
    next.markHandedOff();
    next.finish();
    expect(next.handedOff).toBe(true);
    expect(getInFlightDifyTurn(app, "1", 8)).toBeUndefined();
    await app.close();
    await otherApp.close();
  });

  it("bounds hung calls and resumes tracking once a slot is released", async () => {
    const app = Fastify();
    const turns = Array.from({ length: 1000 }, (_, id) => beginDifyTurn(app, "1", id));
    const overflow = beginDifyTurn(app, "1", 1000);
    overflow.markHandedOff();
    expect(overflow.handedOff).toBe(false);
    expect(getInFlightDifyTurn(app, "1", 1000)).toBeUndefined();
    turns[0].finish();
    const resumed = beginDifyTurn(app, "1", 1001);
    resumed.markHandedOff();
    expect(resumed.handedOff).toBe(true);
    resumed.finish();
    turns.forEach((turn) => turn.finish());
    await app.close();
  });
});
