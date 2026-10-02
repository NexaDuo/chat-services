# frozen_string_literal: true

# Contract of deploy/open_graph.rb (issue #273), run by test-chatwoot-open-graph.sh
# inside the pinned Chatwoot image so it uses the same Ruby and Rack as production.
# No Rails and no network beyond loopback: the middleware only speaks the Rack
# interface, and the tenant lookup is exercised over real HTTP against a local
# stand-in that answers with the middleware's own golden payload.

require 'rack'
require 'socket'
require 'tmpdir'
require_relative ENV.fetch('OPEN_GRAPH_INITIALIZER')

$failures = []
$checks = 0

def check(name, condition)
  $checks += 1
  $failures << name unless condition
end

# Records how the middleware consumed it.
class Body
  attr_reader :each_calls, :close_calls

  def initialize(chunks)
    @chunks = chunks
    @each_calls = 0
    @close_calls = 0
  end

  def each(&block)
    @each_calls += 1
    @chunks.each(&block)
  end

  def close
    @close_calls += 1
  end
end

class FileBody < Body
  def to_path = '/app/public/404.html'
end

class StreamingBody
  attr_reader :called

  def call(_stream) = @called = true
end

# Stand-in for the middleware's GET /public/tenant-branding.
class BrandingServer
  attr_reader :requests
  attr_accessor :reply

  def initialize(reply)
    @server = TCPServer.new('127.0.0.1', 0)
    @requests = []
    @reply = reply
    Thread.new { loop { Thread.new(@server.accept) { |client| serve(client) } } }
  end

  def url = "http://127.0.0.1:#{@server.addr[1]}/public/tenant-branding"

  def serve(client)
    target = client.gets.to_s.split[1]
    nil while (line = client.gets) && line != "\r\n"
    @requests << target
    if @reply == :hang
      sleep 6
    else
      status, body = @reply
      client.write "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    end
  rescue SystemCallError
    nil
  ensure
    client.close
  end
end

def png(width, height)
  "\x89PNG\r\n\x1A\n".b + [13].pack('N') + 'IHDR'.b + [width, height].pack('NN') + "\x08\x02\x00\x00\x00".b
end

def public_dir(files)
  dir = Dir.mktmpdir
  Dir.mkdir(File.join(dir, 'og-images'))
  files.each { |name, bytes| File.binwrite(File.join(dir, 'og-images', name), bytes) }
  dir
end

PUBLIC = public_dir('default.png' => png(1200, 630), 'acme.png' => png(800, 418), 'fake.png' => "\xFF\xD8\xFF\xE0".b + ('x' * 40))
GOLDEN = File.read(ENV.fetch('OPEN_GRAPH_GOLDEN'))

LOG = []
LOGGER = Object.new
%i[info warn error].each { |level| LOGGER.define_singleton_method(level) { |line| LOG << [level, line] } }

def middleware(response, **overrides)
  app = ->(_env) { response }
  options = { frontend_url: 'https://chat.example.test', public_dir: PUBLIC, logger: LOGGER }.merge(overrides)
  ChatServices::OpenGraphTags.new(app, **options)
end

def env(path = '/', method: 'GET', host: 'chat.example.test', forwarded_host: nil)
  base = { 'REQUEST_METHOD' => method, 'PATH_INFO' => path, 'HTTP_HOST' => host, 'SERVER_NAME' => host }
  forwarded_host ? base.merge('HTTP_X_FORWARDED_HOST' => forwarded_host) : base
end

def read(body)
  out = +''.b
  body.each { |chunk| out << chunk.b }
  out
end

def html_headers(extra = {}) = { 'content-type' => 'text/html; charset=utf-8' }.merge(extra)

def utf8(tags) = tags.dup.force_encoding(Encoding::UTF_8)

PAGE = "<!DOCTYPE html>\n<html>\n  <head>\n    <title>Inbox</title>\n  </head>\n  <body>olá</body>\n</html>\n"
PROPERTIES = %w[og:type og:url og:title og:description og:image og:image:type og:image:width og:image:height].freeze

def count(html, property) = html.scan(/<meta property="#{Regexp.escape(property)}" content="/).size

def passes_through(name, response, request = env)
  result = middleware(response).call(request)
  check("#{name}: same response object", result.equal?(response))
  body = response[2]
  check("#{name}: body not consumed", body.each_calls.zero? && body.close_calls.zero?) if body.is_a?(Body)
end

# --- The dashboard page gets every tag exactly once ---------------------------
body = Body.new([PAGE])
status, headers, out = middleware([200, html_headers('content-length' => PAGE.bytesize.to_s), body]).call(env)
html = read(out)
tags = middleware([200, {}, []]).tags
check('dashboard: status kept', status == 200)
check('dashboard: tags sit right before </head>', html == PAGE.b.sub('</head>'.b) { "#{tags}</head>".b })
PROPERTIES.each { |property| check("dashboard: #{property} exactly once", count(html, property) == 1) }
check('dashboard: Content-Length matches the new body', headers['content-length'] == html.bytesize.to_s)
check('dashboard: body read once and closed once', body.each_calls == 1 && body.close_calls == 1)
check('dashboard: og:url is the frontend root', html.include?('<meta property="og:url" content="https://chat.example.test/">'))
check('dashboard: og:image is absolute, versioned by content',
      html.match?(%r{<meta property="og:image" content="https://chat\.example\.test/og-images/default\.png\?v=[0-9a-f]{12}">}))
check('dashboard: dimensions come from the file',
      html.include?('og:image:width" content="1200"') && html.include?('og:image:height" content="630"'))
check('dashboard: neutral default title', html.include?('og:title" content="Multitenant Chat Services"'))
check('dashboard: no tenant or vendor branding by default', !tags.match?(/nexaduo|chatwoot/i))

# No Content-Length from the app: none invented (the server computes it).
_, headers, out = middleware([200, html_headers, Body.new([PAGE])]).call(env)
check('no Content-Length: still injected', count(read(out), 'og:image') == 1)
check('no Content-Length: header not added', headers.keys == ['content-type'])

# Header containers: Rack 3 case-insensitive headers and a legacy mixed-case hash.
rack_headers = Rack::Headers.new.merge!('Content-Type' => 'text/html', 'Content-Length' => PAGE.bytesize.to_s)
_, headers, out = middleware([200, rack_headers, Body.new([PAGE])]).call(env)
check('Rack::Headers: Content-Length updated', headers['content-length'] == read(out).bytesize.to_s)
legacy = { 'Content-Type' => 'text/html', 'Content-Length' => PAGE.bytesize.to_s }
_, headers, out = middleware([200, legacy, Body.new([PAGE])]).call(env)
check('mixed-case hash: Content-Length updated in place',
      headers == { 'Content-Type' => 'text/html', 'Content-Length' => read(out).bytesize.to_s })

# </head> split across chunks, and bytes that are not valid UTF-8.
split = ['<html><head><title>x</title></he', "ad><body>\xFF\xFE</body></html>".b]
_, _, out = middleware([200, html_headers, Body.new(split)]).call(env)
check('split chunks: injected, other bytes intact', read(out) == split.join.b.sub('</head>'.b) { "#{tags}</head>".b })
_, _, out = middleware([200, html_headers, Body.new(['<HTML><HEAD></HEAD ><BODY></BODY></HTML>'])]).call(env)
check('uppercase </HEAD >: injected', read(out).start_with?("<HTML><HEAD>#{tags}</HEAD >".b))

# Forwarded host (Traefik) wins over the upstream Host header; ports are ignored.
_, _, out = middleware([200, html_headers, Body.new([PAGE])]).call(env(host: 'chatwoot-rails:3000', forwarded_host: 'chat.example.test'))
check('X-Forwarded-Host: injected', count(read(out), 'og:image') == 1)
_, _, out = middleware([200, html_headers, Body.new([PAGE])], frontend_url: 'http://127.0.0.1:3000').call(env(host: '127.0.0.1:3000'))
check('non-default port kept in URLs', read(out).include?('content="http://127.0.0.1:3000/og-images/default.png?v='))

# --- Everything else is returned exactly as the app produced it ----------------
passes_through('JSON API', [200, { 'content-type' => 'application/json; charset=utf-8' }, Body.new(['{"a":"</head>"}'])])
passes_through('asset', [200, { 'content-type' => 'text/javascript' }, Body.new(['</head>'])])
passes_through('other text/html-* type', [200, { 'content-type' => 'text/html-sandboxed' }, Body.new([PAGE])])
passes_through('compressed HTML', [200, html_headers('content-encoding' => 'gzip'), Body.new(["\x1F\x8B".b])])
passes_through('chunked HTML', [200, html_headers('transfer-encoding' => 'chunked'), Body.new([PAGE])])
passes_through('partial HTML', [200, html_headers('content-range' => 'bytes 0-9/100'), Body.new([PAGE])])
passes_through('oversized HTML', [200, html_headers('content-length' => (2 * 1024 * 1024).to_s), Body.new([PAGE])])
passes_through('file body', [200, html_headers, FileBody.new([PAGE])])
passes_through('redirect', [302, html_headers('location' => '/app/login'), Body.new([PAGE])])
passes_through('error page', [500, html_headers, Body.new([PAGE])])
passes_through('WebSocket upgrade', [101, { 'upgrade' => 'websocket', 'connection' => 'Upgrade' }, Body.new([])])
passes_through('hijacked socket (ActionCable)', [-1, {}, Body.new([])])
passes_through('HEAD', [200, html_headers, Body.new([PAGE])], env(method: 'HEAD'))
passes_through('POST', [200, html_headers, Body.new([PAGE])], env(method: 'POST'))
passes_through('help center path', [200, html_headers, Body.new([PAGE])], env('/hc/acme/en'))
passes_through('help center root', [200, html_headers, Body.new([PAGE])], env('/hc'))
passes_through('portal custom domain', [200, html_headers, Body.new([PAGE])], env(host: 'help.tenant.test'))
passes_through('portal custom domain via proxy', [200, html_headers, Body.new([PAGE])],
               env(host: 'chat.example.test', forwarded_host: 'help.tenant.test'))
passes_through('container healthcheck host', [200, html_headers, Body.new([PAGE])], env(host: '127.0.0.1:3000'))

streaming = StreamingBody.new
response = [200, html_headers, streaming]
check('streaming body: same response object', middleware(response).call(env).equal?(response))
check('streaming body: never invoked', streaming.called.nil?)

# Pages that describe themselves keep their bytes and their Content-Length.
{
  'existing og:image' => '<meta property="og:image" content="https://cdn.tenant.test/a.png">',
  'existing name=og:image' => '<meta name="og:image" content="https://cdn.tenant.test/a.png">',
  'existing og:title only' => "<meta content='x' property='og:title'>",
  'no </head>' => nil
}.each do |name, tag|
  page = tag ? PAGE.sub('</head>', "#{tag}\n</head>") : '<html><body>fragment</body></html>'
  body = Body.new([page])
  _, headers, out = middleware([200, html_headers('content-length' => page.bytesize.to_s), body]).call(env)
  check("#{name}: bytes identical", read(out) == page.b)
  check("#{name}: Content-Length untouched", headers['content-length'] == page.bytesize.to_s)
  check("#{name}: body closed once", body.close_calls == 1)
end
late = PAGE.sub('<body>', '<body><meta property="og:image" content="x">')
_, _, out = middleware([200, html_headers, Body.new([late])]).call(env)
check('og: text after </head> does not count as a head tag', count(read(out), 'og:title') == 1)

# --- Static configuration ---------------------------------------------------------
custom = utf8(middleware([200, {}, []],
                         title: "Atendimento \xC3\xA9 <\"aqui\"> & l\xC3\xA1".b.force_encoding(Encoding::US_ASCII),
                         description: "  Suporte\n24h  ").tags)
check('custom title: UTF-8 kept, HTML escaped',
      custom.include?("og:title\" content=\"Atendimento é &lt;&quot;aqui&quot;&gt; &amp; lá\">"))
check('custom description: trimmed, control characters flattened', custom.include?('og:description" content="Suporte 24h">'))
check('blank title falls back to the default', middleware([200, {}, []], title: '  ').tags.include?('Multitenant Chat Services'))

swapped = public_dir('default.png' => png(800, 418))
check('swapped artwork: its own dimensions are advertised',
      middleware([200, {}, []], public_dir: swapped).tags.include?('og:image:width" content="800"'))

as_directory = public_dir({})
Dir.mkdir(File.join(as_directory, 'og-images', 'default.png'))
{
  'empty FRONTEND_URL' => { frontend_url: '' },
  'nil FRONTEND_URL' => { frontend_url: nil },
  'FRONTEND_URL without scheme' => { frontend_url: 'chat.example.test' },
  'non-http FRONTEND_URL' => { frontend_url: 'ftp://chat.example.test' },
  'og-images not mounted' => { public_dir: Dir.mktmpdir },
  'missing default image' => { public_dir: public_dir({}) },
  'default image path is a directory' => { public_dir: as_directory },
  'default image is not a PNG' => { public_dir: public_dir('default.png' => "\xFF\xD8\xFF\xE0".b + ('x' * 40)) }
}.each do |name, overrides|
  LOG.clear
  response = [200, html_headers, Body.new([PAGE])]
  instance = middleware(response, **overrides)
  check("#{name}: disabled", instance.tags.nil?)
  check("#{name}: logs a warning", LOG.any? { |level, line| level == :warn && line.include?('[open_graph] disabled') })
  check("#{name}: passes the response through", instance.call(env).equal?(response) && response[2].each_calls.zero?)
end

# --- Tenant branding from the middleware -------------------------------------------
STATIC = middleware([200, {}, []]).tags
now = [1000.0]
clock = -> { now[0] }
server = BrandingServer.new(['200 OK', GOLDEN])
tenant = middleware([200, html_headers, Body.new([PAGE])], branding_url: server.url, clock: clock)

passes = [200, { 'content-type' => 'application/json' }, Body.new(['{}'])]
tenant_json = middleware(passes, branding_url: server.url, clock: clock)
tenant_json.call(env)
tenant_json.call(env('/', host: 'help.tenant.test'))
check('tenant: requests that are not rewritten never trigger a lookup', server.requests.empty?)

_, _, out = tenant.call(env)
page = utf8(read(out))
check('tenant: asks for its own host only', server.requests == ['/public/tenant-branding?host=chat.example.test'])
PROPERTIES.each { |property| check("tenant: #{property} exactly once", count(page, property) == 1) }
check('tenant: title from the golden payload', page.include?('og:title" content="Acme Atendimento">'))
check('tenant: description from the golden payload, HTML escaped',
      page.include?("og:description\" content=\"Fale com a Acme: suporte &amp; vendas &quot;24h&quot; &lt;em um só lugar&gt;.\">"))
check('tenant: image under our /og-images is versioned and sized from the file',
      page.match?(%r{og:image" content="https://chat\.example\.test/og-images/acme\.png\?v=[0-9a-f]{12}">}) &&
      page.include?('og:image:width" content="800"') && page.include?('og:image:height" content="418"'))
check('tenant: og:url stays the frontend root', page.include?('og:url" content="https://chat.example.test/">'))
branded = tenant.tags

5.times { tenant.call(env) }
now[0] += 299
tenant.tags
check('tenant: one lookup serves every request for five minutes', server.requests.size == 1)
now[0] += 2
tenant.tags
check('tenant: refreshed after five minutes', server.requests.size == 2)

server.reply = ['500 Internal Server Error', '{"error":"unavailable"}']
now[0] += 301
check('tenant: a failing middleware keeps the last good answer', tenant.tags == branded && server.requests.size == 3)
now[0] += 29
tenant.tags
check('tenant: failures are not retried per request', server.requests.size == 3)
now[0] += 2
tenant.tags
check('tenant: retried after 30 seconds', server.requests.size == 4)

server.reply = ['404 Not Found', '{"error":"tenant_not_found"}']
now[0] += 31
check('tenant: host no longer owned goes back to the static defaults', tenant.tags == STATIC)
now[0] += 59
tenant.tags
check('tenant: unowned host is rechecked after a minute, not before', server.requests.size == 5)
now[0] += 2
tenant.tags
check('tenant: unowned host rechecked', server.requests.size == 6)

def tenant_tags_for(reply)
  utf8(middleware([200, {}, []], branding_url: BrandingServer.new(reply).url).tags)
end

check('tenant: empty object equals the static defaults', tenant_tags_for(['200 OK', '{}']) == utf8(STATIC))
check('tenant: all-null object equals the static defaults',
      tenant_tags_for(['200 OK', '{"ogTitle":null,"ogDescription":null,"ogImageUrl":null}']) == utf8(STATIC))
['[1,2]', 'not json', '"text"', ''].each do |garbage|
  check("tenant: garbage #{garbage.inspect} falls back to the static defaults", tenant_tags_for(['200 OK', garbage]) == utf8(STATIC))
end
check('tenant: non-string fields are ignored',
      tenant_tags_for(['200 OK', '{"ogTitle":{"a":1},"ogDescription":7,"ogImageUrl":["x"]}']) == utf8(STATIC))
check('tenant: env title is the fallback under a tenant without one',
      utf8(middleware([200, {}, []], title: 'Hub', branding_url: BrandingServer.new(['200 OK', '{"ogDescription":"D"}']).url).tags)
        .then { |t| t.include?('og:title" content="Hub">') && t.include?('og:description" content="D">') })

external = tenant_tags_for(['200 OK', '{"ogTitle":"T","ogImageUrl":"https://cdn.tenant.test/og.jpg?x=1&y=2"}'])
check('tenant: external image is emitted as is', external.include?('og:image" content="https://cdn.tenant.test/og.jpg?x=1&amp;y=2">'))
check('tenant: external image carries no guessed size or type', !external.include?('og:image:'))

{
  'missing file under /og-images' => 'https://chat.example.test/og-images/absent.png',
  'non-PNG file under /og-images' => 'https://chat.example.test/og-images/fake.png',
  'javascript: URL' => 'javascript:alert(1)',
  'relative URL' => '/og-images/acme.png',
  'URL with a quote' => 'https://cdn.tenant.test/a.png\" onload=\"x',
  'URL with a space' => 'https://cdn.tenant.test/a b.png',
  'overlong URL' => "https://cdn.tenant.test/#{'a' * 2100}.png"
}.each do |name, image|
  result = tenant_tags_for(['200 OK', %({"ogTitle":"T","ogImageUrl":"#{image}"})])
  check("tenant image, #{name}: default image advertised instead",
        result.include?('og-images/default.png?v=') && result.include?('og:image:width" content="1200"') && result.include?('og:title" content="T">'))
end
traversal = tenant_tags_for(['200 OK', '{"ogImageUrl":"https://chat.example.test/og-images/../../etc/passwd.png"}'])
check('tenant image, path traversal: no file is read for it', !traversal.include?('og:image:width'))

# Fail open: nothing listening, a server that never answers, a broken setting.
closed = TCPServer.new('127.0.0.1', 0)
refused = "http://127.0.0.1:#{closed.addr[1]}/public/tenant-branding"
closed.close
LOG.clear
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
_, _, out = middleware([200, html_headers, Body.new([PAGE])], branding_url: refused).call(env)
check('middleware down: page still rendered with the static tags', read(out) == PAGE.b.sub('</head>'.b) { "#{STATIC}</head>".b })
check('middleware down: answered immediately', Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 1)
check('middleware down: logged once as a warning', LOG.count { |level, line| level == :warn && line.include?('failed') } == 1)

hanging = BrandingServer.new(:hang)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
slow = middleware([200, {}, []], branding_url: hanging.url)
check('middleware hanging: static tags', slow.tags == STATIC)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
check("middleware hanging: gave up within the read timeout (#{elapsed.round(2)}s)", elapsed < 2.5)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
slow.tags
check('middleware hanging: the next request does not wait again', Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 0.2)

['middleware:4000/public/tenant-branding', 'ftp://middleware/x', '', nil].each do |setting|
  check("branding URL #{setting.inspect}: static only", middleware([200, {}, []], branding_url: setting).tags == STATIC)
end

if $failures.empty?
  puts "open graph contract: #{$checks} checks passed (ruby #{RUBY_VERSION}, rack #{Rack.release})"
else
  warn "open graph contract: #{$failures.size} of #{$checks} checks FAILED"
  $failures.each { |name| warn "  FAIL #{name}" }
  exit 1
end
