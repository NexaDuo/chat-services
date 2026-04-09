import axios, { type AxiosInstance } from "axios";
import type { Logger } from "./logger.js";

/**
 * Minimal Chatwoot REST client — user API (api_access_token).
 * Scope limited to what the middleware needs:
 *   - post outgoing/private messages
 *   - read/write conversation custom_attributes
 *   - toggle status + add labels (for handoff)
 */
export class ChatwootClient {
  private readonly http: AxiosInstance;

  constructor(
    baseUrl: string,
    apiToken: string,
    private readonly logger: Logger,
  ) {
    this.http = axios.create({
      baseURL: baseUrl,
      timeout: 15_000,
      headers: {
        api_access_token: apiToken,
        "Content-Type": "application/json",
      },
    });
  }

  async postMessage(params: {
    accountId: number | string;
    conversationId: number | string;
    content: string;
    private?: boolean;
    messageType?: "outgoing" | "incoming" | "template";
  }): Promise<void> {
    const url = `/api/v1/accounts/${params.accountId}/conversations/${params.conversationId}/messages`;
    await this.http.post(url, {
      content: params.content,
      message_type: params.messageType ?? "outgoing",
      private: params.private ?? false,
    });
    this.logger.debug(
      {
        accountId: params.accountId,
        conversationId: params.conversationId,
        private: params.private ?? false,
      },
      "chatwoot: message posted",
    );
  }

  async setConversationCustomAttributes(params: {
    accountId: number | string;
    conversationId: number | string;
    attributes: Record<string, unknown>;
  }): Promise<void> {
    const url = `/api/v1/accounts/${params.accountId}/conversations/${params.conversationId}/custom_attributes`;
    await this.http.post(url, {
      custom_attributes: params.attributes,
    });
  }

  async toggleConversationStatus(params: {
    accountId: number | string;
    conversationId: number | string;
    status: "open" | "resolved" | "pending" | "snoozed";
  }): Promise<void> {
    const url = `/api/v1/accounts/${params.accountId}/conversations/${params.conversationId}/toggle_status`;
    await this.http.post(url, { status: params.status });
  }

  async addLabels(params: {
    accountId: number | string;
    conversationId: number | string;
    labels: string[];
  }): Promise<void> {
    const url = `/api/v1/accounts/${params.accountId}/conversations/${params.conversationId}/labels`;
    await this.http.post(url, { labels: params.labels });
  }
}
