# Design Spec: scripts/provision-instagram.sh

## Purpose
Automate the creation and configuration of Instagram instances in Evolution API v2, including native integration with Chatwoot.

## Parameters
- `INSTANCE_NAME`: Unique name for the Evolution API instance.
- `CHATWOOT_ACCOUNT_ID`: The ID of the account in Chatwoot where conversations will be synced.

## Environment Variables (from `.env`)
- `EVOLUTION_AUTHENTICATION_API_KEY`: API key for Evolution Manager.
- `EVOLUTION_CHATWOOT_URL`: Public or internal URL of Chatwoot for Evolution to connect to.
- `CHATWOOT_API_TOKEN`: Admin or User access token for Chatwoot.

## Robustness Features
- `set -euo pipefail` for strict error handling.
- Validation of input arguments.
- Check for existence of `.env`.
- Improved parsing of `.env` to handle potential quotes or whitespace.
- Basic check for `curl` output to ensure API calls were successful (checking for `true` or success indicators in JSON).

## Logic Flow
1. Check if both arguments are provided.
2. Search for `.env` in the current directory and parent directory.
3. Extract required variables from `.env`.
4. Define `EVO_URL` (defaulting to `http://localhost:8080` if not overridden).
5. Call Evolution API `/instance/create` with `integration: instagram`.
6. Call Evolution API `/chatwoot/set/{instance}` with provided account ID and Chatwoot credentials.

## Testing Strategy
- Run with missing arguments to verify error message.
- Run with missing `.env` to verify error message.
- Run with missing variables in `.env` to verify error message.
- (Verification of actual API calls will be done in Task 3/4).
