/**
 * Generic per-key debounce + grouping coordinator.
 *
 * Built for issue #179: the Chatwoot webhook handler used to call Dify once
 * per incoming HTTP request, with zero coordination across requests for the
 * same conversation. A burst of N messages arriving within a couple of
 * seconds of each other (e.g. Instagram splitting a shared-post + caption
 * into two `message_created` events) produced N parallel Dify calls and N
 * outgoing replies. This class groups everything that arrives for the same
 * key within `windowMs` of the last item and hands the group to `flush` in
 * one call — the domain logic (Dify + Chatwoot + watermark) lives entirely
 * in the caller-supplied `flush` callback, this module knows nothing about
 * webhooks.
 *
 * Concurrency model (deliberately simple — see AGENTS.md "single
 * environment"): the middleware runs as exactly one process, so a per-key
 * `Map` with `setTimeout` is sufficient; there is no multi-instance race to
 * guard against. Coordination is per-key only — different keys never block
 * each other.
 *
 * Restart behavior (explicit, per issue #179 acceptance criteria): all of
 * this state is in-memory. If the process restarts while a group is
 * buffered (timer armed, not yet fired), that buffer is lost with it — the
 * messages in it are simply never answered. This is the accepted tradeoff:
 * dropping one group's answer silently is preferable to answering a group
 * twice. No watermark is advanced for a lost group (persistence happens
 * only after `flush` succeeds), so nothing is later mistaken for "already
 * handled" — the next real message the contact sends starts a fresh group
 * and is answered normally.
 */

export type FlushGroup<M> = {
  key: string;
  messages: M[];
};

export type FlushHandler<M> = (group: FlushGroup<M>) => Promise<void>;

type ConversationState<M> = {
  messages: M[];
  timer: ReturnType<typeof setTimeout> | null;
  flushing: boolean;
};

export class ConversationDebouncer<M> {
  private readonly states = new Map<string, ConversationState<M>>();

  constructor(
    private readonly windowMs: number,
    private readonly flush: FlushHandler<M>,
    private readonly onError: (key: string, err: unknown) => void,
  ) {}

  /**
   * Adds `message` to the pending group for `key` and (re)arms its debounce
   * timer — every new message for the same key pushes the flush out by
   * `windowMs` again, which is what turns a burst into a single group.
   */
  enqueue(key: string, message: M): void {
    const state = this.stateFor(key);
    state.messages.push(message);
    if (state.timer) clearTimeout(state.timer);
    state.timer = setTimeout(() => {
      state.timer = null;
      void this.runFlush(key);
    }, this.windowMs);
  }

  /** Number of keys with any in-memory state (buffered or in-flight). For tests/metrics. */
  get activeKeyCount(): number {
    return this.states.size;
  }

  /** Cancels all pending timers without flushing. Use on shutdown/tests only. */
  clearAll(): void {
    for (const state of this.states.values()) {
      if (state.timer) clearTimeout(state.timer);
    }
    this.states.clear();
  }

  private stateFor(key: string): ConversationState<M> {
    let state = this.states.get(key);
    if (!state) {
      state = { messages: [], timer: null, flushing: false };
      this.states.set(key, state);
    }
    return state;
  }

  private async runFlush(key: string): Promise<void> {
    const state = this.states.get(key);
    if (!state) return;
    // A flush is already in flight for this key. The message(s) that armed
    // this timer are still sitting in state.messages — they are picked up
    // by the in-flight flush's `finally` below once it completes, forming
    // the *next* group. This is what guarantees a message that arrives
    // during Dify generation is answered once, in the next group, and
    // never merged into (or reprocessed with) the group already in flight.
    if (state.flushing) return;
    if (state.messages.length === 0) return;

    const messages = state.messages;
    state.messages = [];
    state.flushing = true;
    try {
      await this.flush({ key, messages });
    } catch (err) {
      this.onError(key, err);
    } finally {
      state.flushing = false;
      if (state.messages.length > 0) {
        state.timer = setTimeout(() => {
          state.timer = null;
          void this.runFlush(key);
        }, this.windowMs);
      } else if (!state.timer) {
        // Idle: nothing pending, nothing scheduled — free the map entry.
        this.states.delete(key);
      }
    }
  }
}
