# Instagram Integration Guide for NexaDuo Tenant

This guide describes how to integrate a new Instagram account into the **NexaDuo** tenant (Account ID: 1).

## Prerequisites

1.  **Instagram Professional Account**: The Instagram account must be a **Business** or **Creator** account.
2.  **Facebook Page**: The Instagram account must be linked to a Facebook Page.
3.  **Facebook Developer Account**: You need access to the Facebook Developer Portal.

## Step 1: Facebook Developer Portal Setup

1.  Go to [developers.facebook.com](https://developers.facebook.com/).
2.  Create a new App (type: "Other" -> "Business").
3.  Add the **Instagram Graph API** product to your app.
4.  Configure the **Webhook** to point to your Evolution API URL (if not handled automatically by Evolution).
    *   *Note: Evolution API v2 usually manages the webhook subscription automatically when you connect the instance.*

## Step 2: Provision the Instance in NexaDuo Stack

Run the following command on the production server (or via CI/CD if configured):

```bash
./scripts/provision-instagram.sh nexaduo-instagram 1
```

This will:
*   Create a new instance named `nexaduo-instagram` in the Evolution API.
*   Configure the Chatwoot integration for Account ID `1` (NexaDuo).

## Step 3: Connect the Account (via Browser)

1.  Open the Evolution API Dashboard (if available) or use the API to get the connection URL.
2.  Alternatively, monitor the logs to get the Pairing Code or QR Code:
    ```bash
    docker compose logs -f evolution-api
    ```
3.  Follow the instructions in the logs to authenticate.
    *   For Instagram, you might need to use the Pairing Code method or provide the Instagram username/password depending on the Evolution API version settings.

## Step 4: Verify in Chatwoot

1.  Login to [chat.nexaduo.com](https://chat.nexaduo.com).
2.  Go to **Settings** -> **Inboxes**.
3.  You should see a new **API Channel** created by the Evolution API.
4.  Send a Direct Message to your Instagram account and verify it appears in Chatwoot.

## Step 5: Verify AI Agent (Dify)

1.  The Middleware is already configured to monitor Account ID `1`.
2.  When a message arrives in the new Instagram inbox in Chatwoot, the Middleware will automatically forward it to Dify.
3.  Check the Middleware logs to ensure processing:
    ```bash
    docker compose logs -f middleware
    ```

---
**Guide created on:** 2026-05-19
