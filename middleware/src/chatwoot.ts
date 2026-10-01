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
 * Minimal Chatwoot REST client — user token, optional bot identity for replies.
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
    private readonly botToken?: string,
  ) {
    this.http = axios.create({
      baseURL: baseUrl,
      timeout: 15_000,
      headers: {
        api_access_token: apiToken,
        "Content-Type": "application/json",
      },
    });
    this.http.interceptors.response.use(undefined, (error: unknown) => {
      // Axios errors carry request headers (including either access token).
      // Callers log errors and may include their message in a private note.
      const status = axios.isAxiosError(error) ? error.response?.status : undefined;
      throw new Error(`Chatwoot request failed${status ? ` (HTTP ${status})` : ""}`);
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
    const useBotToken = this.botToken && !params.private && (params.messageType ?? "outgoing") === "outgoing";
    const response = await this.http.post<ChatwootMessageResponse>(
      url,
      {
        content: params.content,
        message_type: params.messageType ?? "outgoing",
        private: params.private ?? false,
      },
      useBotToken ? { headers: { api_access_token: this.botToken } } : undefined,
    );
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

  async getConversation(params: {
    accountId: number | string;
    conversationId: number | string;
  }): Promise<unknown> {
    const url = `/api/v1/accounts/${params.accountId}/conversations/${params.conversationId}`;
    const { data } = await this.http.get(url);
    // v4.13 REST show omits both assignment keys for an unassigned conversation;
    // EventDataPresenter (webhooks) emits explicit nulls. Normalize ONLY that
    // documented REST shape, leaving partial/invalid metadata to fail closed.
    if (
      data?.meta && typeof data.meta === "object" &&
      typeof data.meta.channel === "string" && data.meta.sender &&
      Object.hasOwn(data.meta, "hmac_verified") &&
      !Object.hasOwn(data.meta, "assignee") && !Object.hasOwn(data.meta, "assignee_type")
    ) {
      return { ...data, meta: { ...data.meta, assignee: null, assignee_type: null } };
    }
    return data;
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
