import axios, { type AxiosInstance } from "axios";
import type { Readable } from "node:stream";
import type { Logger } from "./logger.js";

export type DifyChatResponse = {
  /** Message ID returned by Dify for this turn. */
  message_id: string;
  /** Dify conversation_id — must be persisted across turns for memory. */
  conversation_id: string;
  /** Assistant answer. */
  answer: string;
  metadata?: {
    usage?: {
      prompt_tokens?: number;
      completion_tokens?: number;
      total_tokens?: number;
    };
  };
};

export type DifyChatRequest = {
  query: string;
  user: string;
  conversationId?: string;
  inputs?: Record<string, unknown>;
};

/**
 * Minimal Dify Chat API client (Service API, per-app Bearer key).
 * Supports blocking (Chatflow) and streaming (Agent) modes.
 */
export class DifyClient {
  private readonly http: AxiosInstance;

  constructor(
    baseUrl: string,
    apiKey: string,
    timeoutMs: number,
    private readonly logger: Logger,
  ) {
    this.http = axios.create({
      baseURL: baseUrl,
      timeout: timeoutMs,
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
    });
  }

  async chatBlocking(req: DifyChatRequest): Promise<DifyChatResponse> {
    const payload = {
      inputs: req.inputs ?? {},
      query: req.query,
      user: req.user,
      conversation_id: req.conversationId ?? "",
      response_mode: "blocking" as const,
      auto_generate_name: false,
    };
    this.logger.debug({ user: req.user }, "dify: chat-messages (blocking)");
    const { data } = await this.http.post<DifyChatResponse>(
      "/chat-messages",
      payload,
    );
    return data;
  }

  /**
   * Streaming variant for Agent apps (which do not support blocking mode).
   * Consumes SSE events and returns the same DifyChatResponse shape.
   */
  async chatStreaming(req: DifyChatRequest): Promise<DifyChatResponse> {
    const payload = {
      inputs: req.inputs ?? {},
      query: req.query,
      user: req.user,
      conversation_id: req.conversationId ?? "",
      response_mode: "streaming" as const,
      auto_generate_name: false,
    };
    this.logger.debug({ user: req.user }, "dify: chat-messages (streaming)");
    const { data: stream } = await this.http.post<Readable>(
      "/chat-messages",
      payload,
      { responseType: "stream" },
    );

    return new Promise<DifyChatResponse>((resolve, reject) => {
      let answer = "";
      let messageId = "";
      let conversationId = "";
      let metadata: DifyChatResponse["metadata"] = undefined;
      let buffer = "";

      stream.on("data", (chunk: Buffer) => {
        buffer += chunk.toString();

        // SSE format: each event is "data: {json}\n\n"
        const parts = buffer.split("\n\n");
        // Keep the last (possibly incomplete) part in the buffer.
        buffer = parts.pop()!;

        for (const part of parts) {
          for (const line of part.split("\n")) {
            if (!line.startsWith("data: ")) continue;
            const json = line.slice(6);

            let evt: Record<string, unknown>;
            try {
              evt = JSON.parse(json);
            } catch {
              continue;
            }

            const event = evt.event as string;

            if (event === "agent_message" || event === "message") {
              answer += (evt.answer as string) ?? "";
              if (!messageId) messageId = (evt.message_id as string) ?? "";
              if (!conversationId)
                conversationId = (evt.conversation_id as string) ?? "";
            } else if (event === "message_end") {
              if (!messageId) messageId = (evt.message_id as string) ?? "";
              if (!conversationId)
                conversationId = (evt.conversation_id as string) ?? "";
              metadata = evt.metadata as DifyChatResponse["metadata"];
            } else if (event === "error") {
              const code = (evt.code as string) ?? "unknown";
              const msg = (evt.message as string) ?? "unknown error";
              reject(new Error(`Dify streaming error [${code}]: ${msg}`));
              stream.destroy();
              return;
            }
            // ping, agent_thought, message_file — ignored
          }
        }
      });

      stream.on("end", () => {
        resolve({
          message_id: messageId,
          conversation_id: conversationId,
          answer,
          metadata,
        });
      });

      stream.on("error", (err: Error) => {
        reject(err);
      });
    });
  }
}
