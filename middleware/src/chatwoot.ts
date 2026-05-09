import axios, { type AxiosInstance } from "axios";
import type { Logger } from "./logger.js";

export type ChatwootMessageResponse = {
  id: number;
  content: string;
  private: boolean;
  message_type: string;
  created_at: string;
};

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
  }): Promise<ChatwootMessageResponse> {
    const url = `/api/v1/accounts/${params.accountId}/conversations/${params.conversationId}/messages`;
    const response = await this.http.post<ChatwootMessageResponse>(url, {
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
    return response.data;
  }

  async setConversationCustomAttributes(params: {
    accountId: number | string;
    conversationId: number | string;
    attributes: Record<string, unknown>;
  }): Promise<Record<string, unknown>> {
    const url = `/api/v1/accounts/${params.accountId}/conversations/${params.conversationId}/custom_attributes`;
    const response = await this.http.post<Record<string, unknown>>(url, {
      custom_attributes: params.attributes,
    });
    return response.data;
  }

  async toggleConversationStatus(params: {
    accountId: number | string;
    conversationId: number | string;
    status: "open" | "resolved" | "pending" | "snoozed";
  }): Promise<{ status: string }> {
    const url = `/api/v1/accounts/${params.accountId}/conversations/${params.conversationId}/toggle_status`;
    const response = await this.http.post<{ status: string }>(url, { 
      status: params.status 
    });
    return response.data;
  }

  async addLabels(params: {
    accountId: number | string;
    conversationId: number | string;
    labels: string[];
  }): Promise<{ labels: string[] }> {
    const url = `/api/v1/accounts/${params.accountId}/conversations/${params.conversationId}/labels`;
    const response = await this.http.post<{ labels: string[] }>(url, { 
      labels: params.labels 
    });
    return response.data;
  }
}
