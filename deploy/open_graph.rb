# frozen_string_literal: true

# --- Explicit Open Graph tags on the Chatwoot HTML (issue #273) ---------------
# Chatwoot's dashboard layout (`app/views/layouts/vueapp.html.erb`) emits no
# `og:*` tags, so link-preview crawlers (Meta Sharing Debugger: "inferred
# property og:image") guess an image from the favicons. This initializer adds a
# small Rack middleware that inserts explicit tags before `</head>`.
#
# Where the text and the picture come from, in this order:
# 1. The tenant that owns this Chatwoot host, from the tenant config: the
#    middleware's `GET /public/tenant-branding?host=<FRONTEND_URL host>`
#    (`tenants.og_title`, `og_description`, `og_image_url`; the owner is the
#    active tenant holding Chatwoot account 1 on the host). Looked up at most
#    once every few minutes, never per request, with short timeouts.
# 2. `CHATWOOT_OG_TITLE` / `CHATWOOT_OG_DESCRIPTION`, when set.
# 3. Neutral built-in text and `deploy/og-images/default.png`.
# The lookup fails open: if the middleware is down, slow or answers garbage,
# the last good answer is kept, or the static values of 2 and 3 are used. The
# page itself is never delayed by more than the timeouts below and never fails.
#
# Checked against Chatwoot v4.18.0-ce (Rails 7.2.3.1, Rack 3.2.6, Puma 7.2.1):
# - No `Rack::Deflater` anywhere in the image, so responses reach this
#   middleware uncompressed. It is still appended with `middleware.use`, which
#   makes it the innermost middleware: anything that compresses, adds an ETag
#   or serves /app/public (`ActionDispatch::Static`) runs outside it and sees
#   the final body. A response that already carries `Content-Encoding` is
#   passed through untouched anyway.
# - The help-center layouts (`layouts/portal*`, `public/api/v1/portals/**`)
#   emit their own, per-portal `og:*` tags, some of them without `og:image`.
#   Those pages are never touched: see the scoping rules in
#   `candidate_request?` and `inject`.
#
# It depends only on the Rack middleware API, not on Chatwoot internals. It is
# mounted read-only into `chatwoot-rails` (deploy/docker-compose.chatwoot.yml)
# together with `deploy/og-images/`, which lands in `/app/public/og-images/`
# and is served by Rails' static file server.
#
# Anything this middleware cannot handle safely is returned exactly as the app
# produced it (same bytes, same headers). If the static configuration is
# unusable (bad FRONTEND_URL, missing or non-PNG default image) it disables
# itself at boot and logs why, instead of advertising a broken preview.

require 'cgi'
require 'digest'
require 'json'
require 'net/http'
require 'timeout'
require 'uri'

module ChatServices
  class OpenGraphTags
    DEFAULT_TITLE = 'Multitenant Chat Services'
    DEFAULT_DESCRIPTION = 'Omnichannel customer conversations in one shared inbox.'
    IMAGE_DIR = 'og-images'
    DEFAULT_IMAGE = 'default.png'
    LOCAL_IMAGE = %r{\A/#{IMAGE_DIR}/([A-Za-z0-9][A-Za-z0-9._-]*\.png)\z}
    PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze
    # Dashboard pages are ~10 KB. Past this size it is not one of them.
    MAX_HTML_BYTES = 1024 * 1024
    HEAD_CLOSE = %r{</head\s*>}in
    EXISTING_OG = /<meta\b[^>]*\b(?:property|name)\s*=\s*["']?og:/in
    HTML_TYPE = %r{\Atext/html(?:\s*;|\s*\z)}i

    # Tenant lookup: seconds. A page waits at most LOOKUP_DEADLINE, once per
    # refresh, and only the one request that performs the refresh.
    OPEN_TIMEOUT = 1
    READ_TIMEOUT = 1
    LOOKUP_DEADLINE = 3
    REFRESH_AFTER = 300 # a tenant answered
    RECHECK_AFTER = 60  # no tenant owns this host
    RETRY_AFTER = 30    # the lookup failed
    MAX_LOOKUP_BYTES = 16 * 1024
    MAX_TITLE = 200
    MAX_DESCRIPTION = 500
    MAX_URL = 2048

    def initialize(app, frontend_url:, public_dir:, title: nil, description: nil, branding_url: nil, logger: nil,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @app = app
      @logger = logger
      @clock = clock
      @images = File.join(public_dir.to_s, IMAGE_DIR)
      @lock = Mutex.new
      @static_tags = nil
      @branding_uri = nil
      @tenant_tags = nil
      @lookup_state = nil
      @next_lookup = 0
      configure(frontend_url, title, description, branding_url)
    end

    def call(env)
      response = @app.call(env)
      return response unless @static_tags && candidate_request?(env)

      status, headers, body = response
      return response unless candidate_response?(status, headers, body)

      rewrite(status, headers, body)
    end

    # The tags the next dashboard page will carry (nil when disabled).
    def tags
      return nil unless @static_tags

      refresh_tenant if @branding_uri && @clock.call >= @next_lookup
      @tenant_tags || @static_tags
    end

    private

    # Only plain GETs for the dashboard host. The help center is excluded twice:
    # by path (`/hc/...` on the main host) and by host (a portal on its own
    # custom domain is served from `/`).
    def candidate_request?(env)
      return false unless env['REQUEST_METHOD'] == 'GET'

      path = env['PATH_INFO'].to_s
      return false if path == '/hc' || path.start_with?('/hc/')

      request_host(env) == @host
    end

    def request_host(env)
      raw = env['HTTP_X_FORWARDED_HOST'].to_s.split(',').last.to_s.strip
      raw = env['HTTP_HOST'].to_s if raw.empty?
      raw = env['SERVER_NAME'].to_s if raw.empty?
      raw.sub(/:\d+\z/, '').downcase
    end

    # A complete, uncompressed, in-memory HTML document. Everything else (JSON,
    # assets, WebSocket upgrades, file bodies, Rack 3 streaming bodies that only
    # respond to `call`) is not ours to buffer.
    def candidate_response?(status, headers, body)
      return false unless status.to_i == 200 && headers.respond_to?(:each)
      return false unless HTML_TYPE.match?(header(headers, 'content-type').to_s)

      encoding = header(headers, 'content-encoding').to_s.strip.downcase
      return false unless encoding.empty? || encoding == 'identity'
      return false if header(headers, 'transfer-encoding')
      return false if header(headers, 'content-range')

      length = header(headers, 'content-length')
      return false if length && length.to_s.to_i > MAX_HTML_BYTES

      body.respond_to?(:each) && !body.respond_to?(:to_path)
    end

    def rewrite(status, headers, body)
      chunks = []
      begin
        body.each { |chunk| chunks << chunk }
      ensure
        body.close if body.respond_to?(:close)
      end

      [status, headers, inject(headers, chunks) || chunks]
    end

    # Returns the new body, or nil to keep the buffered chunks as they are.
    def inject(headers, chunks)
      html = chunks.join.b
      return nil if html.bytesize > MAX_HTML_BYTES

      at = html.index(HEAD_CLOSE)
      return nil unless at
      # Any existing og:* tag means the page describes itself (help center).
      return nil if EXISTING_OG.match?(html.byteslice(0, at))

      html.insert(at, tags)
      length_key = header_key(headers, 'content-length')
      headers[length_key] = html.bytesize.to_s if length_key
      [html]
    rescue StandardError => e
      log(:error, "left a response untouched after #{e.class}: #{e.message}")
      nil
    end

    def header_key(headers, name)
      return name if headers.respond_to?(:key?) && headers.key?(name)

      headers.each { |key, _| return key if key.to_s.downcase == name }
      nil
    end

    def header(headers, name)
      key = header_key(headers, name)
      key && headers[key]
    end

    # --- Static configuration (boot) ------------------------------------------

    def configure(frontend_url, title, description, branding_url)
      @base = public_base(frontend_url)
      return disable("FRONTEND_URL is not an absolute http(s) URL: #{frontend_url.inspect}") unless @base

      @default_image = local_image(DEFAULT_IMAGE)
      return disable("#{File.join(@images, DEFAULT_IMAGE)} is missing or is not a PNG") unless @default_image

      @title = text(title, MAX_TITLE) || DEFAULT_TITLE
      @description = text(description, MAX_DESCRIPTION) || DEFAULT_DESCRIPTION
      @static_tags = render(@title, @description, @default_image)
      @branding_uri = lookup_uri(branding_url)
      log(:info, "enabled for #{@host}: #{@default_image[:url]}; tenant branding from #{@branding_uri || 'nowhere (static only)'}")
    rescue StandardError => e
      @static_tags = nil
      disable("#{e.class}: #{e.message}")
    end

    def public_base(frontend_url)
      uri = URI.parse(frontend_url.to_s.strip)
      return nil unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?

      @host = uri.host.downcase
      port = uri.port == uri.default_port ? '' : ":#{uri.port}"
      "#{uri.scheme}://#{@host}#{port}"
    rescue URI::InvalidURIError
      nil
    end

    def lookup_uri(branding_url)
      value = branding_url.to_s.strip
      return nil if value.empty?

      uri = URI.parse(value)
      return uri if uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?

      log(:warn, "ignoring CHATWOOT_OG_BRANDING_URL, not an absolute http(s) URL: #{value.inspect}")
      nil
    rescue URI::InvalidURIError
      log(:warn, "ignoring CHATWOOT_OG_BRANDING_URL, not an absolute http(s) URL: #{value.inspect}")
      nil
    end

    # A PNG we serve ourselves from /app/public/og-images: its real size is
    # advertised, and its digest versions the URL so crawlers that cache images
    # by URL pick up new artwork.
    def local_image(name)
      file = File.join(@images, name)
      header = File.binread(file, 24)
      return nil unless header && header.bytesize == 24
      return nil unless header.byteslice(0, 8) == PNG_SIGNATURE && header.byteslice(12, 4) == 'IHDR'.b

      width, height = header.byteslice(16, 8).unpack('NN')
      { url: "#{@base}/#{IMAGE_DIR}/#{name}?v=#{Digest::SHA256.file(file).hexdigest[0, 12]}",
        type: 'image/png', width: width, height: height }
    rescue SystemCallError
      nil
    end

    def render(title, description, image)
      pairs = [
        ['og:type', 'website'],
        ['og:url', "#{@base}/"],
        ['og:title', title],
        ['og:description', description],
        ['og:image', image[:url]]
      ]
      pairs << ['og:image:type', image[:type]] if image[:type]
      pairs << ['og:image:width', image[:width].to_s] << ['og:image:height', image[:height].to_s] if image[:width]
      pairs.map { |property, content| %(<meta property="#{property}" content="#{CGI.escapeHTML(content)}">\n) }.join.b.freeze
    end

    # ENV and JSON strings: force UTF-8 (ENV carries the locale encoding, which
    # is not UTF-8 in every container), drop control characters, cap the length.
    def text(value, limit)
      return nil unless value.is_a?(String)

      value = value.dup.force_encoding(Encoding::UTF_8).scrub('').gsub(/[[:cntrl:]]+/, ' ').strip
      value.empty? ? nil : value[0, limit]
    end

    # --- Tenant branding (runtime, cached) ------------------------------------

    # One thread refreshes; the others keep serving what is already cached.
    def refresh_tenant
      return unless @lock.try_lock

      begin
        return unless @clock.call >= @next_lookup

        state, delay = lookup
        @next_lookup = @clock.call + delay
        return if state == @lookup_state

        @lookup_state = state
        log(state.start_with?('failed') ? :warn : :info, "tenant branding for #{@host}: #{state}")
      ensure
        @lock.unlock
      end
    end

    # Returns [what happened, seconds until the next lookup].
    def lookup
      response = Timeout.timeout(LOOKUP_DEADLINE) { fetch }
      case response.code.to_i
      when 200
        @tenant_tags, summary = tenant_tags(JSON.parse(response.body.to_s.byteslice(0, MAX_LOOKUP_BYTES)))
        [summary, REFRESH_AFTER]
      when 404
        @tenant_tags = nil
        ['no tenant owns this host, using the static defaults', RECHECK_AFTER]
      else
        ["failed (HTTP #{response.code}), keeping #{kept}", RETRY_AFTER]
      end
    rescue StandardError, Timeout::Error => e
      ["failed (#{e.class}), keeping #{kept}", RETRY_AFTER]
    end

    def kept
      @tenant_tags ? 'the last tenant answer' : 'the static defaults'
    end

    # Never through a proxy (third argument nil): this is an in-network call.
    def fetch
      uri = @branding_uri.dup
      uri.query = URI.encode_www_form(host: @host)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.write_timeout = READ_TIMEOUT
      http.max_retries = 0
      http.request_get(uri.request_uri, 'Accept' => 'application/json')
    end

    def tenant_tags(payload)
      raise TypeError, 'tenant branding is not a JSON object' unless payload.is_a?(Hash)

      title = text(payload['ogTitle'], MAX_TITLE)
      description = text(payload['ogDescription'], MAX_DESCRIPTION)
      image, note = tenant_image(payload['ogImageUrl'])
      summary = "title #{title ? 'from tenant' : 'default'}, description #{description ? 'from tenant' : 'default'}, image #{note}"
      [render(title || @title, description || @description, image || @default_image), summary]
    end

    # The tenant's image must be an absolute http(s) URL. One that points at our
    # own /og-images/ must exist there as a PNG, or the default is used instead
    # of advertising a 404. Any other URL is emitted as is, without dimensions:
    # this process never fetches a tenant-supplied URL.
    def tenant_image(value)
      url = text(value, MAX_URL + 1)
      return [nil, 'default (none configured)'] unless url
      return [nil, 'default (tenant URL rejected)'] if url.length > MAX_URL || url.match?(/[\s"'<>]/)

      uri = URI.parse(url)
      return [nil, 'default (tenant URL rejected)'] unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
      return [{ url: url }, 'from tenant (external)'] unless uri.host.downcase == @host

      name = uri.path.to_s[LOCAL_IMAGE, 1]
      return [{ url: url }, 'from tenant (this host)'] unless name

      image = local_image(name)
      image ? [image, "from tenant (#{IMAGE_DIR}/#{name})"] : [nil, "default (#{IMAGE_DIR}/#{name} is missing or not a PNG)"]
    rescue URI::InvalidURIError
      [nil, 'default (tenant URL rejected)']
    end

    def disable(reason)
      log(:warn, "disabled, no tags will be added: #{reason}")
      nil
    end

    def log(level, message)
      line = "[open_graph] #{message} (issue #273)"
      @logger ? @logger.public_send(level, line) : warn(line)
    end
  end
end

if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
  Rails.application.config.middleware.use(
    ChatServices::OpenGraphTags,
    frontend_url: ENV.fetch('FRONTEND_URL', nil),
    public_dir: Rails.public_path,
    title: ENV.fetch('CHATWOOT_OG_TITLE', nil),
    description: ENV.fetch('CHATWOOT_OG_DESCRIPTION', nil),
    branding_url: ENV.fetch('CHATWOOT_OG_BRANDING_URL', nil),
    logger: Rails.logger
  )
end
