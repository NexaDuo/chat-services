# Real Message callbacks -> AgentBotListener -> AgentBots::WebhookJob -> HTTP
# tap -> actual middleware. Inline jobs make the negative control deterministic:
# all producer callbacks and HTTP deliveries finish before the assertion.
require 'json'
require 'net/http'
require 'logger'
Rails.logger = Logger.new(File::NULL)
ActiveRecord::Base.logger = nil
ActiveJob::Base.logger = Logger.new(File::NULL)
ActiveJob::Base.queue_adapter = :inline

begin
  account = Account.create!(name: "Agent Bot contract #{SecureRandom.hex(4)}")
  bot = AgentBot.create!(name: 'CI contract bot', outgoing_url: 'http://middleware:4100/webhooks/chatwoot')
  inboxes = %w[bot human].map do |name|
    channel = Channel::Api.create!(account: account)
    Inbox.create!(account: account, channel: channel, name: "contract-#{name}", enable_auto_assignment: false)
  end
  AgentBotInbox.create!(inbox: inboxes.first, agent_bot: bot, status: :active)
  messages = inboxes.map do |inbox|
    contact = Contact.create!(account: account, name: 'Contract contact')
    link = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.uuid)
    conversation = Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: link)
    # Do not set initial status or build a webhook fixture: Chatwoot owns both.
    conversation.messages.create!(account: account, inbox: inbox, sender: contact,
                                  content: 'Agent Bot contract probe', message_type: :incoming)
  end
  # Exercise the real top-level conversation webhook shape via model callbacks.
  messages.first.conversation.reload.update!(status: :open)
  response = Net::HTTP.get_response(URI('http://middleware:4100/events'))
  raise 'Receiver unavailable' unless response.code == '200'
  events = JSON.parse(response.body)
  raise 'Non-2xx middleware delivery' unless events.all? { |event| (200...300).cover?(event['http_status']) }
  delivered = events.select { |event| event['event'] == 'message_created' && event['id'] == messages.first.id }
  raise 'Bot event missing or duplicated' unless delivered.size == 1
  event = delivered.first
  raise 'Wrong account/status' unless event['account_id'] == account.id && event['status'] == 'pending'
  non_messages = events.select do |item|
    item['event'].to_s.start_with?('conversation_') &&
      item['conversation_id'] == messages.first.conversation.display_id
  end
  raise 'Non-message bot event missing' if non_messages.empty?
  raise 'Non-message event not acknowledged' unless non_messages.all? do |item|
    item.dig('result', 'skipped') == 'not_message_created'
  end
  # No tenant is configured for this isolated account: reaching no_tenant_mapping
  # proves the real middleware accepted the payload AND passed ownership gating.
  raise 'Middleware rejected bot event' unless event['http_status'] == 200 &&
                                              event.dig('result', 'skipped') == 'no_tenant_mapping'
  raise 'Unattached inbox delivered an event' if events.any? do |item|
    (item['event'] == 'message_created' && item['id'] == messages.last.id) ||
      item['conversation_id'] == messages.last.conversation.display_id
  end
  raise 'Unattached inbox unexpectedly pending' unless messages.last.conversation.reload.open?
  puts 'PASS: real Agent Bot message is pending and reaches middleware; non-message events are acknowledged; all deliveries are 2xx; unattached inbox delivers nothing (2 messages).'
rescue StandardError => error
  warn "FAIL: Agent Bot producer contract (#{error.class}); payload/credentials withheld."
  exit 1
ensure
  # Fixtures are in the ephemeral CI database; workflow teardown removes them.
  bot&.update!(outgoing_url: nil)
end
