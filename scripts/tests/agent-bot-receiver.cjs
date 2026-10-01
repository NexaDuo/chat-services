// CI-only tap inside the middleware container. Forward the real producer body
// unchanged; retain only rule fields and the middleware result, never URL/token.
const http = require('node:http');
const fs = require('node:fs');
const events = [];
fs.writeFileSync('/tmp/agent-bot-contract.pid', String(process.pid));
http.createServer(async (req, res) => {
  if (req.method === 'GET') {
    res.end(JSON.stringify(events));
    return;
  }
  try {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    const event = JSON.parse(body);
    const url = new URL('http://127.0.0.1:4000/webhooks/chatwoot');
    if (process.env.CHATWOOT_WEBHOOK_TOKEN) url.searchParams.set('token', process.env.CHATWOOT_WEBHOOK_TOKEN);
    const response = await fetch(url, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body,
    });
    const result = await response.json();
    if (event.event === 'message_created' && event.message_type === 'incoming') {
      events.push({
        id: event.id, account_id: event.account?.id,
        status: event.conversation?.status,
        meta: {
          assignee: event.conversation?.meta?.assignee,
          assignee_type: event.conversation?.meta?.assignee_type,
        },
        http_status: response.status, result,
      });
    }
    res.statusCode = response.status;
    res.end('{}');
  } catch {
    res.statusCode = 500;
    res.end('{}');
  }
}).listen(4100, '0.0.0.0');
