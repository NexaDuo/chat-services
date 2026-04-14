import { Hono } from 'hono'

type Bindings = {
  CHAT_ORIGIN: string
  DIFY_ORIGIN: string
  MIDDLEWARE_URL: string
  SHARED_SECRET: string
}

const app = new Hono<{ Bindings: Bindings }>()

// Simple in-memory cache for slug -> accountId mappings
// Max size and TTL (10 minutes)
const TENANT_CACHE = new Map<string, { accountId: string, expiresAt: number }>()
const CACHE_TTL_MS = 10 * 60 * 1000 // 10 minutes

/**
 * HTMLRewriter to fix absolute paths in responses.
 * Converts paths like "/assets/app.js" to "/{tenant}/assets/app.js"
 */
class TenantRewriter {
  tenant: string
  constructor(tenant: string) {
    this.tenant = tenant
  }

  element(element: any) {
    const attributes = ['src', 'href', 'action']
    for (const attr of attributes) {
      const val = element.getAttribute(attr)
      if (val && val.startsWith('/') && !val.startsWith(`/${this.tenant}`)) {
        element.setAttribute(attr, `/${this.tenant}${val}`)
      }
    }
  }
}

/**
 * Resolve tenant slug to accountId via Middleware
 */
async function resolveTenant(tenant: string, env: Bindings): Promise<string | null> {
  // 1. Check Cache
  const cached = TENANT_CACHE.get(tenant)
  if (cached && cached.expiresAt > Date.now()) {
    return cached.accountId
  }

  // 2. Fetch from Middleware
  try {
    const response = await fetch(`${env.MIDDLEWARE_URL}/resolve-tenant?subdomain=${tenant}`, {
      headers: {
        'Authorization': `Bearer ${env.SHARED_SECRET}`
      }
    })

    if (!response.ok) {
      console.error(`Failed to resolve tenant ${tenant}: ${response.status} ${response.statusText}`)
      return null
    }

    const data = await response.json() as { accountId: string }
    const accountId = data.accountId

    // 3. Update Cache
    TENANT_CACHE.set(tenant, {
      accountId,
      expiresAt: Date.now() + CACHE_TTL_MS
    })

    return accountId
  } catch (error) {
    console.error(`Error resolving tenant ${tenant}:`, error)
    return null
  }
}

app.all('/:tenant/*', async (c) => {
  const tenant = c.req.param('tenant')
  const env = c.env
  const url = new URL(c.req.url)
  const hostname = url.hostname

  // 1. Resolve Tenant ID
  const accountId = await resolveTenant(tenant, env)
  if (!accountId) {
    return c.text('Tenant not found', 404)
  }

  // 2. Determine Backend Origin
  let originHostname = env.CHAT_ORIGIN
  if (hostname.includes('dify')) {
    originHostname = env.DIFY_ORIGIN
  }

  // 3. Handle WebSocket Upgrade
  const upgradeHeader = c.req.header('Upgrade')
  if (upgradeHeader === 'websocket') {
    const wsUrl = new URL(c.req.url)
    wsUrl.hostname = originHostname
    // Path stripping for WebSockets too
    wsUrl.pathname = wsUrl.pathname.replace(`/${tenant}`, '') || '/'
    
    // Inject headers for WebSockets
    const headers = new Headers(c.req.raw.headers)
    headers.set('X-Tenant-ID', accountId)
    headers.set('Host', originHostname)

    return fetch(wsUrl.toString(), {
      ...c.req.raw,
      headers
    })
  }

  // 4. Prepare Proxy Request
  const proxyUrl = new URL(c.req.url)
  proxyUrl.hostname = originHostname
  // Path Stripping: /tenant/path -> /path
  proxyUrl.pathname = proxyUrl.pathname.replace(`/${tenant}`, '') || '/'

  const proxyRequest = new Request(proxyUrl.toString(), c.req.raw)
  
  // 5. Inject Multi-Tenant Headers
  proxyRequest.headers.set('X-Tenant-ID', accountId)
  proxyRequest.headers.set('Host', originHostname)
  
  // 6. Fetch from Origin
  const response = await fetch(proxyRequest)

  // 7. Rewrite HTML for Absolute Asset Paths
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
