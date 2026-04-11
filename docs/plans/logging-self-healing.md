# Logging & Self-Healing Agent Implementation Plan

## Background & Motivation
The current infrastructure leverages Grafana and Prometheus for metrics but relies on standard Docker JSON-file logs. To achieve better observability and enable proactive maintenance, a centralized logging stack is required. Additionally, an LLM-driven "self-healing" agent will continuously analyze error logs to identify root causes and propose actionable fixes, reducing the mean time to resolution (MTTR).

## Scope & Impact
- **Docker Compose**: Add three new services: `loki`, `promtail`, and `self-healing-agent`.
- **Observability Configuration**: Add `loki.yaml` and `promtail.yaml` to configure log ingestion.
- **Grafana Provisioning**: Add a Loki datasource and a new "Self-Healing Insights" dashboard.
- **Database**: Update the Postgres initialization script to create a new `self_healing` database with an `insights` table to store LLM analyses.
- **Agent Service**: Create a new Node.js service under `agents/self-healing/` responsible for tailing logs, interacting with the LLM, and persisting the results.
- **Documentation**: This plan will be saved to `docs/plans/logging-self-healing.md`.

## Proposed Solution
1. **Log Aggregation (Promtail + Loki)**:
   - **Promtail** will run as a container, bind-mounting `/var/lib/docker/containers` (read-only) to scrape the `json-file` logs from all running containers.
   - It will push these logs to **Loki**, which will index them.
   - **Grafana** will be configured to query Loki, allowing manual log exploration.

2. **Self-Healing Agent**:
   - A dedicated **Node.js** container service will run continuously.
   - It will query the Loki HTTP API periodically (e.g., every 5 minutes) for logs matching `level=error` or `level=fatal` across the `nexaduo` stack.
   - The agent will deduplicate recent errors to avoid redundant LLM calls.
   - It will format the error stack trace and context and send it to an LLM (e.g., via a Dify Workflow or directly using an OpenAI/Gemini API key).
   - The LLM's response (root cause analysis and proposed fix) will be inserted into the `insights` table in the new `self_healing` Postgres database.
   - These insights will be visualized in a dedicated Grafana dashboard for the engineering team to review and act upon.

## Alternatives Considered
- **Docker Native Loki Driver**: Rejected in favor of the Promtail container approach to avoid requiring host-level Docker plugin installations, keeping the stack fully portable within `docker-compose`.
- **Cron Script vs Dedicated Service**: Rejected the cron script approach in favor of a dedicated service container, which provides better state management (for deduplication) and lifecycle alignment with the rest of the stack.
- **Direct Notification vs Database Logging**: Chose to log the issues into a Postgres table (which Grafana can query) rather than sending immediate webhooks, minimizing noise and alert fatigue while maintaining an actionable audit trail.

## Implementation Steps
1. **Step 1: Provision Loki and Promtail**:
   - Create `observability/loki/loki.yaml` and `observability/promtail/promtail.yaml`.
   - Add `loki` and `promtail` services to `docker-compose.yml`.
2. **Step 2: Grafana & Postgres Setup**:
   - Add `observability/grafana/provisioning/datasources/loki.yml`.
   - Update `infrastructure/postgres/01-init.sql` to create the `self_healing` DB.
3. **Step 3: Implement the Self-Healing Agent**:
   - Scaffold a Node.js project in `agents/self-healing/`.
   - Implement the Loki polling logic and the LLM integration.
   - Implement the Postgres insertion logic.
   - Create a `Dockerfile` for the agent.
4. **Step 4: Integrate the Agent**:
   - Add the `self-healing-agent` service to `docker-compose.yml`.
   - Create a sample Grafana dashboard JSON to visualize the `insights` table.

## Verification
- Verify that `promtail` is successfully pushing container logs to `loki` by querying Grafana Explorer.
- Simulate an error in the middleware container and verify that the `self-healing-agent` detects it, calls the LLM, and successfully logs a proposed fix into the `self_healing` database.
- Verify the new Grafana dashboard displays the generated insight.