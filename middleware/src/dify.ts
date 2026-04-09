import axios, { type AxiosInstance } from "axios";
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
 * Only covers the blocking `chat-messages` endpoint.
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
}
