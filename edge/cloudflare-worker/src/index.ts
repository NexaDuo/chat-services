import { Hono } from 'hono'

type Bindings = {
  CHAT_ORIGIN: string
  DIFY_ORIGIN: string
  MIDDLEWARE_URL: string
  SHARED_SECRET: string
}

const app = new Hono<{ Bindings: Bindings }>()

/**
 * HTMLRewriter to fix absolute paths in responses.
 * Converts paths like "/assets/app.js" to "/{tenant}/assets/app.js"
 */
class TenantRewriter {
  tenant: string
  constructor(tenant: string) {
    this.tenant = tenant
  }

  element(element: Element) {
    const attributes = ['src', 'href', 'action']
    for (const attr of attributes) {
      const val = element.getAttribute(attr)
      if (val && val.startsWith('/') && !val.startsWith(`/${this.tenant}`)) {
        element.setAttribute(attr, `/${this.tenant}${val}`)
      }
    }
  }
}

app.all('/:tenant/*', async (c) => {
  const tenant = c.req.param('tenant')
  const url = new URL(c.req.url)
  const hostname = url.hostname

  // 1. Determine Backend Origin
  let originHostname = c.env.CHAT_ORIGIN
  if (hostname.includes('dify')) {
    originHostname = c.env.DIFY_ORIGIN
  }

  // 2. Handle WebSocket Upgrade
  const upgradeHeader = c.req.header('Upgrade')
  if (upgradeHeader === 'websocket') {
    const wsUrl = new URL(c.req.url)
    wsUrl.hostname = originHostname
    // Path stripping for WebSockets too
    wsUrl.pathname = wsUrl.pathname.replace(`/${tenant}`, '') || '/'
    
    return fetch(wsUrl.toString(), c.req.raw)
  }

  // 3. Prepare Proxy Request
  const proxyUrl = new URL(c.req.url)
  proxyUrl.hostname = originHostname
  // Path Stripping: /tenant/path -> /path
  proxyUrl.pathname = proxyUrl.pathname.replace(`/${tenant}`, '') || '/'

  const proxyRequest = new Request(proxyUrl.toString(), c.req.raw)
  
  // 4. Inject Multi-Tenant Headers
  proxyRequest.headers.set('X-Tenant-ID', tenant)
  proxyRequest.headers.set('Host', originHostname)
  
  // 5. Fetch from Origin
  const response = await fetch(proxyRequest)

  // 6. Rewrite HTML for Absolute Asset Paths
  const contentType = response.headers.get('Content-Type') || ''
  if (contentType.includes('text/html')) {
    const rewriter = new HTMLRewriter()
      .on('script', new TenantRewriter(tenant))
      .on('link', new TenantRewriter(tenant))
      .on('img', new TenantRewriter(tenant))
      .on('form', new TenantRewriter(tenant))
      .on('a', new TenantRewriter(tenant))
    
    return rewriter.transform(response)
  }

  return response
})

// Default route for health check or root access
app.get('/', (c) => {
  return c.text('NexaDuo Edge Router Active')
})

export default app
