# Invoked by provision-chatwoot-bot.sh inside Chatwoot v4.13. No credential output,
# including SQL binds, ActiveJob arguments, validation errors or exception messages.
require 'json'
require 'uri'
require 'logger'
Rails.logger = Logger.new(File::NULL)
ActiveRecord::Base.logger = nil
ActiveJob::Base.logger = Logger.new(File::NULL)

class BotProvisioningError < StandardError; end

begin
  config = JSON.parse(STDIN.read)
  endpoint_key = lambda do |value|
    uri = URI.parse(value)
    raise BotProvisioningError, 'Invalid endpoint' unless %w[http https].include?(uri.scheme) && uri.host &&
                                    uri.path == '/webhooks/chatwoot' && !uri.userinfo && !uri.fragment
    [uri.scheme, uri.host, uri.port, uri.path]
  end
  endpoint_key.call(config.fetch('endpoint'))
  uri = URI.parse(config.fetch('endpoint'))
  raise BotProvisioningError, 'Endpoint must not contain a query' if uri.query
  raise BotProvisioningError, 'Webhook token required' if config.fetch('webhook_token').empty?
  uri.query = URI.encode_www_form(token: config.fetch('webhook_token'))
  endpoints = config.fetch('legacy_endpoints').map { |url| endpoint_key.call(url) }
  endpoints << endpoint_key.call(config.fetch('endpoint'))
  selectors = config.fetch('inboxes')
  raise BotProvisioningError, 'Expected inbox array' unless selectors.is_a?(Array)
  if selectors.empty?
    puts '[agent-bot] No inboxes declared; populate provisioning/chatwoot-agent-bot.json before cutover.'
    raise BotProvisioningError, 'Empty cutover refused' if config['apply']
    exit 0
  end

  ActiveRecord::Base.transaction do
    # Serialize concurrent provisioning runs. All validation precedes all writes.
    ActiveRecord::Base.connection.execute('SELECT pg_advisory_xact_lock(250, 1)')
    bots = AgentBot.where(account_id: nil, name: config.fetch('name')).to_a
    raise BotProvisioningError, 'Ambiguous global bot' if bots.size > 1
    bot = bots.first || AgentBot.new(account_id: nil, name: config.fetch('name'))
    inboxes = selectors.map do |selector|
      raise BotProvisioningError, 'Invalid account id' unless selector.fetch('account_id').is_a?(Integer) && selector['account_id'].positive?
      # Names survive database rebuilds unlike inbox ids. Channel type adds a
      # cross-check; names must be managed as stable configuration by operators.
      matches = Inbox.where(account_id: selector.fetch('account_id'), name: selector.fetch('name'),
                            channel_type: selector.fetch('channel_type')).to_a
      raise BotProvisioningError, 'Missing or ambiguous inbox' unless matches.size == 1
      inbox = matches.first
      bindings = AgentBotInbox.where(inbox_id: inbox.id).to_a
      raise BotProvisioningError, 'Inbox belongs to another bot or has duplicate bindings' if bindings.size > 1 ||
        bindings.any? { |binding| bot.new_record? || binding.agent_bot_id != bot.id }
      inbox
    end
    raise BotProvisioningError, 'Duplicate inbox selector' unless inboxes.map(&:id).uniq.size == inboxes.size
    hooks = Webhook.account_type.to_a.select do |hook|
      begin
        endpoints.include?(endpoint_key.call(hook.url))
      rescue URI::InvalidURIError, BotProvisioningError
        false
      end
    end
    stale = bot.persisted? ? bot.agent_bot_inboxes.where.not(inbox_id: inboxes.map(&:id)).to_a : []
    puts "[agent-bot] #{config['apply'] ? 'APPLY' : 'DRY-RUN'}: global bot #{bot.persisted? ? 'update' : 'create'}"
    inboxes.each { |inbox| puts "[agent-bot] attach account_id=#{inbox.account_id} inbox_id=#{inbox.id}" }
    stale.each { |binding| puts "[agent-bot] deactivate inbox_id=#{binding.inbox_id}" }
    hooks.each { |hook| puts "[agent-bot] remove account webhook account_id=#{hook.account_id} id=#{hook.id}" }
    if config['apply']
      bot.update!(outgoing_url: uri.to_s, bot_type: :webhook)
      token = config.fetch('bot_token')
      bot.access_token.update!(token: token) unless token.empty? || bot.access_token.token == token
      inboxes.each do |inbox|
        binding = AgentBotInbox.find_or_initialize_by(inbox_id: inbox.id)
        binding.update!(agent_bot: bot, status: :active)
      end
      stale.each { |binding| binding.update!(status: :inactive) }
      hooks.each(&:destroy!)
    end
  end
  puts '[agent-bot] Complete; credentials withheld.'
rescue StandardError => error
  # ActiveRecord errors can embed outgoing_url or access-token SQL binds.
  detail = error.is_a?(BotProvisioningError) ? error.message : error.class.name
  warn "[agent-bot] FAILED (#{detail}); transaction rolled back; credentials withheld."
  exit 1
end
