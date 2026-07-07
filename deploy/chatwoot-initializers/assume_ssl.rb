# frozen_string_literal: true

# --- Trust the proxy's forwarded scheme (issue #95) ---------------------------
# Behind the Cloudflare tunnel, TLS is terminated at the edge and the request is
# forwarded to Traefik (the `http` entrypoint) over plain HTTP. As a result Rails
# sees the request as `http`, so `request.base_url` (and therefore
# `ActionController::RequestForgeryProtection#valid_request_origin?`) computes an
# `http://chat.nexaduo.com` base while the browser sends an `https://...` Origin
# header. The scheme mismatch fails `verified_request?` and every PATCH/POST in the
# Rails `/super_admin` panel returns HTTP 422 (`unverified_request`).
#
# Chatwoot v4.13.0 runs `config.load_defaults 7.0` and never wires the
# `RAILS_ASSUME_SSL` env into `config.assume_ssl`, so setting the env alone is inert.
# This initializer wires it: when `RAILS_ASSUME_SSL` is truthy, `config.assume_ssl`
# inserts `ActionDispatch::AssumeSSL`, which normalizes the rack env to https
# (`HTTPS=on`, `HTTP_X_FORWARDED_PROTO=https`, `rack.url_scheme=https`). `base_url`
# becomes `https://...`, the Origin check passes, and the 422s stop.
#
# IMPORTANT: `assume_ssl` only makes Rails *believe* the request is SSL — it does NOT
# redirect. It is distinct from `force_ssl`/`FORCE_SSL` (kept `false` here on purpose),
# so it cannot cause the Cloudflare SSL redirect loop documented in AGENTS.md.
if ActiveModel::Type::Boolean.new.cast(ENV.fetch('RAILS_ASSUME_SSL', false))
  Rails.application.config.assume_ssl = true
  Rails.logger.info('[assume_ssl] RAILS_ASSUME_SSL enabled — trusting forwarded https scheme (issue #95)') if Rails.logger
end
