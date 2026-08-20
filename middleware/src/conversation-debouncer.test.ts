import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { ConversationDebouncer } from "./conversation-debouncer.js";

/**
 * Regression tests for issue #179 (burst → duplicate replies).
 *
 * Root cause: the webhook handler called Dify once per incoming HTTP
 * request with zero coordination across requests for the same conversation.
 * These tests pin the generic grouping primitive in isolation from the
 * webhook/Dify/Chatwoot wiring (covered separately in
 * chatwoot-webhook.test.ts), using fake timers so the debounce window is
 * deterministic instead of flaky wall-clock waiting.
 */
describe("ConversationDebouncer", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("groups two messages that arrive within the debounce window into ONE flush call", async () => {
    // This is the exact incident shape from issue #179: msg 83 at t=0,
    // msg 84 at t=1.5s (same conversation) — both must produce exactly one
    // Dify call / one outgoing reply, not two.
    const flush = vi.fn().mockResolvedValue(undefined);
    const debouncer = new ConversationDebouncer<{ id: number; content: string }>(
      2500,
      flush,
      () => {},
    );

    debouncer.enqueue("acct:conv-8", { id: 83, content: "Shared post" });
    await vi.advanceTimersByTimeAsync(1500);
    debouncer.enqueue("acct:conv-8", { id: 84, content: "que linda vc está nesta foto" });
    await vi.advanceTimersByTimeAsync(2500);

    expect(flush).toHaveBeenCalledTimes(1);
    expect(flush).toHaveBeenCalledWith({
      key: "acct:conv-8",
      messages: [
        { id: 83, content: "Shared post" },
        { id: 84, content: "que linda vc está nesta foto" },
      ],
    });
  });

  it("does not flush a single message before the debounce window elapses", async () => {
    const flush = vi.fn().mockResolvedValue(undefined);
    const debouncer = new ConversationDebouncer<{ id: number; content: string }>(
      2500,
      flush,
      () => {},
    );

    debouncer.enqueue("acct:conv-1", { id: 1, content: "oi" });
    await vi.advanceTimersByTimeAsync(2000);
    expect(flush).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(500);
    expect(flush).toHaveBeenCalledTimes(1);
  });

  it("a message arriving while a flush is in flight lands in the NEXT group, not the current one", async () => {
    // Simulates the case explicitly called out by the acceptance criteria:
    // a message that arrives during Dify generation must not be merged
    // into (or lost from) the group already being processed.
    let resolveFirstFlush!: () => void;
    const flush = vi
      .fn()
      .mockImplementationOnce(
        () =>
          new Promise<void>((resolve) => {
            resolveFirstFlush = resolve;
          }),
      )
      .mockResolvedValueOnce(undefined);
    const debouncer = new ConversationDebouncer<{ id: number; content: string }>(
      100,
      flush,
      () => {},
    );

    debouncer.enqueue("acct:conv-2", { id: 1, content: "first" });
    await vi.advanceTimersByTimeAsync(100); // first flush starts, hangs on the unresolved promise

    expect(flush).toHaveBeenCalledTimes(1);

    // A second message arrives while the first flush is still "generating".
    debouncer.enqueue("acct:conv-2", { id: 2, content: "second" });
    await vi.advanceTimersByTimeAsync(100); // its own timer fires, but flushing=true, so nothing happens yet

    expect(flush).toHaveBeenCalledTimes(1); // still just the one in-flight call

    resolveFirstFlush();
    await vi.waitFor(() => expect(flush).toHaveBeenCalledTimes(1)); // let the finally{} run

    // Now the finally{} block should have rearmed a timer for the second message.
    await vi.advanceTimersByTimeAsync(100);

    expect(flush).toHaveBeenCalledTimes(2);
    expect(flush).toHaveBeenNthCalledWith(2, {
      key: "acct:conv-2",
      messages: [{ id: 2, content: "second" }],
    });
  });

  it("processes different conversations independently — no global lock", async () => {
    const flush = vi.fn().mockResolvedValue(undefined);
    const debouncer = new ConversationDebouncer<{ id: number; content: string }>(
      100,
      flush,
      () => {},
    );

    debouncer.enqueue("acct:conv-A", { id: 1, content: "a1" });
    debouncer.enqueue("acct:conv-B", { id: 1, content: "b1" });
    await vi.advanceTimersByTimeAsync(100);

    expect(flush).toHaveBeenCalledTimes(2);
    const keys = flush.mock.calls.map((call) => call[0].key).sort();
    expect(keys).toEqual(["acct:conv-A", "acct:conv-B"]);
  });

  it("calls onError and keeps working for subsequent groups when flush rejects", async () => {
    const onError = vi.fn();
    const flush = vi
      .fn()
      .mockRejectedValueOnce(new Error("dify down"))
      .mockResolvedValueOnce(undefined);
    const debouncer = new ConversationDebouncer<{ id: number }>(50, flush, onError);

    debouncer.enqueue("acct:conv-3", { id: 1 });
    await vi.advanceTimersByTimeAsync(50);
    await vi.waitFor(() => expect(onError).toHaveBeenCalledTimes(1));
    expect(onError).toHaveBeenCalledWith("acct:conv-3", expect.any(Error));

    debouncer.enqueue("acct:conv-3", { id: 2 });
    await vi.advanceTimersByTimeAsync(50);
    expect(flush).toHaveBeenCalledTimes(2);
  });
});
