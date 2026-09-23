import { authHeaders } from '../auth'
import { icons } from '../icons'

interface CheckResult {
  name: string
  desc: string
  status: 'ok' | 'fail'
  detail: string
  latency?: number
}

const TIMEOUT_MS = 10000

/** Keep the deadline active until the response body has finished reading. */
export async function fetchWithTimeout(path: string, options: RequestInit = {}): Promise<{ response: Response; body: string; latency: number }> {
  const controller = new AbortController()
  const started = performance.now()
  const timeout = setTimeout(() => controller.abort(), TIMEOUT_MS)
  try {
    const response = await fetch(path, { ...options, signal: controller.signal })
    const body = await response.text()
    return { response, body, latency: Math.round(performance.now() - started) }
  } catch (error) {
    if (controller.signal.aborted) throw new Error(`Timed out after ${TIMEOUT_MS / 1000}s`)
    throw error
  } finally {
    clearTimeout(timeout)
  }
}

const CHECKS: { name: string; desc: string; run: () => Promise<Omit<CheckResult, 'name' | 'desc'>> }[] = [
  {
    name: 'Server liveness',
    desc: '/healthz responds (does not test authentication or upstream)',
    run: async () => {
      const { response, latency } = await fetchWithTimeout('/healthz')
      return { status: response.ok ? 'ok' : 'fail', detail: `HTTP ${response.status}`, latency }
    },
  },
  {
    name: 'Accounts',
    desc: 'At least one account configured',
    run: async () => {
      const { response, body, latency } = await fetchWithTimeout('/zed/accounts', { headers: authHeaders() })
      if (!response.ok) return { status: 'fail', detail: `HTTP ${response.status}`, latency }
      const data = JSON.parse(body)
      if (!Array.isArray(data.accounts)) return { status: 'fail', detail: 'Invalid accounts response', latency }
      const count = data.accounts.length
      if (count === 0) return { status: 'fail', detail: 'No accounts configured', latency }
      const current = data.accounts.find((account: { current?: boolean }) => account.current)
      return { status: 'ok', detail: `${count} account(s), active: ${current?.name ?? 'none'}`, latency }
    },
  },
  {
    name: 'Token refresh',
    desc: 'Current account can obtain a Zed JWT',
    run: async () => {
      const { response, body, latency } = await fetchWithTimeout('/zed/usage', { headers: authHeaders() })
      if (!response.ok) return { status: 'fail', detail: `HTTP ${response.status} — check account credentials`, latency }
      const data = JSON.parse(body)
      return { status: 'ok', detail: `Plan: ${data.plan ?? 'unknown'}`, latency }
    },
  },
  {
    name: 'Model catalog',
    desc: '/v1/models responds; the list may be cached or static',
    run: async () => {
      const { response, body, latency } = await fetchWithTimeout('/v1/models', { headers: authHeaders() })
      if (!response.ok) return { status: 'fail', detail: `HTTP ${response.status}`, latency }
      const data = JSON.parse(body)
      if (!Array.isArray(data.data)) return { status: 'fail', detail: 'Invalid model catalog', latency }
      const source = response.headers.get('X-Models-Source')
      const suffix = source === 'static' ? ' (static fallback; upstream unverified)'
        : source === 'stale' ? ' (stale cache; upstream unavailable)'
        : source === 'cache' ? ' (cached from upstream)'
        : source === 'upstream' ? ' (upstream)'
        : ' (source unknown; upstream unverified)'
      return { status: source === 'static' || source === 'stale' ? 'fail' : 'ok', detail: `${data.data.length} models listed${suffix}`, latency }
    },
  },
]

export function renderHealth() {
  const page = document.getElementById('page-health')!
  page.innerHTML = `
    <div class="page-header" style="display:flex;align-items:flex-end;justify-content:space-between">
      <div>
        <h2>Health Check</h2>
        <p>Verify server liveness, account credentials, and catalog availability.</p>
      </div>
      <button class="btn" id="rerun-btn">
        ${icons.refresh} Re-run
      </button>
    </div>
    <div class="page-body">
      <div class="health-summary" id="health-summary"></div>
      <div class="health-list" id="health-list"></div>
    </div>
  `

  document.getElementById('rerun-btn')!.addEventListener('click', () => { void runChecks() })
  void runChecks()
}

let checking = false

async function runChecks() {
  if (checking) return
  checking = true
  const button = document.getElementById('rerun-btn') as HTMLButtonElement
  button.disabled = true
  const list = document.getElementById('health-list')!
  const summary = document.getElementById('health-summary')!

  list.innerHTML = CHECKS.map(c => `
    <div class="health-row pending">
      <div class="health-status"><span class="spinner"></span></div>
      <div class="health-info">
        <div class="health-name">${c.name}</div>
        <div class="health-desc">${c.desc}</div>
      </div>
      <div class="health-detail">Checking...</div>
    </div>
  `).join('')

  summary.innerHTML = `<div class="health-summary-text"><span class="spinner"></span> Running checks...</div>`

  try {
    const results = await Promise.all(CHECKS.map(async (c, i): Promise<CheckResult> => {
      let result: CheckResult
      try {
        const r = await c.run()
        result = { name: c.name, desc: c.desc, ...r }
      } catch (e) {
        result = { name: c.name, desc: c.desc, status: 'fail', detail: e instanceof Error ? e.message : 'error' }
      }

      const row = list.querySelectorAll('.health-row')[i]
      if (row) {
        row.className = `health-row ${result.status}`
        row.innerHTML = `
          <div class="health-status">${result.status === 'ok' ? icons.checkCircle : icons.xCircle}</div>
          <div class="health-info">
            <div class="health-name">${result.name}</div>
            <div class="health-desc">${result.desc}</div>
          </div>
          <div class="health-right">
            <div class="health-detail">${esc(result.detail)}</div>
            ${result.latency != null ? `<div class="health-latency">${result.latency}ms</div>` : ''}
          </div>
        `
      }
      return result
    }))

    const passed = results.filter(r => r.status === 'ok').length
    const total = results.length
    const allOk = passed === total
    summary.innerHTML = `
      <div class="health-summary-icon ${allOk ? 'ok' : 'warn'}">
        ${allOk ? icons.checkCircle : icons.alertCircle}
      </div>
      <div>
        <div class="health-summary-title">${allOk ? 'All checks passed' : `${passed}/${total} checks passed`}</div>
        <div class="health-summary-sub">Last checked: ${new Date().toLocaleTimeString()}</div>
      </div>
    `
  } finally {
    checking = false
    button.disabled = false
  }
}

function esc(s: string): string {
  const d = document.createElement('div')
  d.textContent = s
  return d.innerHTML
}
