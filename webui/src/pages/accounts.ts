import { fetchAccounts, fetchUsage, fetchBilling, switchAccount, deleteAccount, uploadAccounts, type UsageInfo } from '../api'
import { icons } from '../icons'
import { showToast } from '../toast'

function esc(s: string): string {
  const d = document.createElement('div')
  d.textContent = s
  return d.innerHTML
}

export function renderAccounts() {
  const page = document.getElementById('page-accounts')!
  page.innerHTML = `
    <div class="page-header">
      <h2>Accounts</h2>
      <p>Manage your Zed accounts and credentials.</p>
    </div>
    <div class="page-body">
      <div class="account-list" id="account-list"></div>

      <div class="upload-zone" id="upload-zone">
        <input type="file" id="accounts-file" accept=".json,application/json" hidden />
        <div class="upload-icon">${icons.upload}</div>
        <div class="upload-title">Upload accounts.json</div>
        <div class="upload-desc">
          Drag &amp; drop your <code>accounts.json</code> here, or click to browse.
          Generate it with the desktop auth tool (Windows).
        </div>
        <div class="upload-actions">
          <button class="btn btn-primary" id="browse-btn">
            <span>${icons.upload}</span> Choose file
          </button>
          <span class="upload-hint" id="upload-status">No file selected</span>
        </div>
      </div>

      <div class="upload-help">
        <div class="upload-help-title"><span>${icons.info}</span> How authorization works</div>
        <ol>
          <li>Run the <code>zed2api-auth</code> desktop tool on a Windows machine that can sign in to Zed.</li>
          <li>The tool logs in via GitHub OAuth and writes <code>accounts.json</code>.</li>
          <li>Upload that file here. It replaces any accounts currently configured.</li>
        </ol>
      </div>

      <div class="usage-section" id="usage-section" style="display:none"></div>
    </div>
  `

  const fileInput = document.getElementById('accounts-file') as HTMLInputElement
  const zone = document.getElementById('upload-zone')!
  const browseBtn = document.getElementById('browse-btn') as HTMLButtonElement

  browseBtn.addEventListener('click', () => fileInput.click())
  zone.addEventListener('click', (e) => {
    // Don't double-trigger when the user clicks the button itself.
    if (e.target === browseBtn || browseBtn.contains(e.target as Node)) return
    fileInput.click()
  })
  fileInput.addEventListener('change', () => {
    if (fileInput.files && fileInput.files.length > 0) handleFile(fileInput.files[0])
  })

  // Drag & drop
  zone.addEventListener('dragover', (e) => {
    e.preventDefault()
    zone.classList.add('dragover')
  })
  zone.addEventListener('dragleave', () => zone.classList.remove('dragover'))
  zone.addEventListener('drop', (e) => {
    e.preventDefault()
    zone.classList.remove('dragover')
    const f = e.dataTransfer?.files?.[0]
    if (f) handleFile(f)
  })

  loadAccounts()
}

async function handleFile(file: File) {
  const status = document.getElementById('upload-status')!
  status.textContent = `Uploading ${file.name} ...`
  status.classList.remove('error')
  try {
    const res = await uploadAccounts(file)
    status.textContent = `Uploaded ${res.count} account(s): ${res.accounts.join(', ')}`
    showToast(`Uploaded ${res.count} account(s)`)
    loadAccounts()
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    status.textContent = `Failed: ${msg}`
    status.classList.add('error')
    showToast(`Upload failed: ${msg}`)
  }
}

async function loadAccounts() {
  const list = document.getElementById('account-list')!
  try {
    const data = await fetchAccounts()
    const accs = data.accounts || []
    document.getElementById('acc-count')!.textContent = String(accs.length)
    if (accs.length === 0) {
      list.innerHTML = `<div class="empty-state">
        <div class="empty-icon">${icons.users}</div>
        <div>No accounts configured yet. Upload accounts.json below.</div>
      </div>`
      document.getElementById('usage-section')!.style.display = 'none'
      return
    }
    list.innerHTML = accs.map(acc => `
      <div class="account-card ${acc.current ? 'active' : ''}">
        <div class="account-avatar">${esc(acc.name.charAt(0).toUpperCase())}</div>
        <div class="account-info">
          <div class="account-name">${esc(acc.name)}</div>
          <div class="account-meta">ID: ${esc(acc.user_id)}</div>
        </div>
        <div class="account-actions">
          ${acc.current
            ? `<span class="tag tag-active">${icons.check} Active</span>`
            : `<button class="btn switch-btn" data-name="${esc(acc.name)}">Switch</button>`}
          <button class="btn delete-btn" data-name="${esc(acc.name)}" title="Remove account">
            ${icons.trash}
          </button>
        </div>
      </div>
    `).join('')

    list.querySelectorAll<HTMLButtonElement>('.switch-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const name = btn.dataset.name!
        await switchAccount(name)
        showToast(`Switched to ${name}`)
        loadAccounts()
      })
    })
    list.querySelectorAll<HTMLButtonElement>('.delete-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const name = btn.dataset.name!
        if (!confirm(`Remove account "${name}"? This deletes it from accounts.json.`)) return
        await deleteAccount(name)
        showToast(`Removed ${name}`)
        loadAccounts()
      })
    })
    if (accs.some(a => a.current)) loadUsage()
  } catch (e) {
    list.innerHTML = `<div class="error-state">
      Failed to load accounts: ${e instanceof Error ? esc(e.message) : 'unknown error'}
    </div>`
  }
}

async function loadUsage() {
  const section = document.getElementById('usage-section')!
  try {
    const usage: UsageInfo = await fetchUsage()
    const billing = await fetchBilling().catch(() => null) as Record<string, unknown> | null
    if (billing?.plan && typeof billing.plan === 'object') {
      const planObj = billing.plan as Record<string, unknown>
      const period = planObj.subscription_period as Record<string, string> | undefined
      if (period?.started_at && period?.ended_at) {
        usage.subscriptionPeriod = [period.started_at, period.ended_at]
      }
    }
    section.style.display = 'block'
    section.innerHTML = renderUsageCard(usage)
  } catch {
    section.style.display = 'none'
  }
}

function renderUsageCard(u: UsageInfo): string {
  const plan = u.plan || 'Unknown'
  const limitCents = u.monthly_spending_limit_in_cents ?? 2000
  const limit = (limitCents / 100).toFixed(2)

  const period = u.subscriptionPeriod
  let periodHtml = ''
  if (period && period.length === 2) {
    const end = new Date(period[1])
    const days = Math.ceil((end.getTime() - Date.now()) / 86400000)
    periodHtml = `<div class="usage-stat">
      <div class="usage-stat-label">Expires</div>
      <div class="usage-stat-value">${end.toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' })} <small>(${days}d)</small></div>
    </div>`
  }

  return `
    <div class="usage-card">
      <div class="usage-card-header">
        <span class="usage-card-icon">${icons.activity}</span>
        <h3>Usage</h3>
      </div>
      <div class="usage-stats">
        <div class="usage-stat">
          <div class="usage-stat-label">Plan</div>
          <div class="usage-stat-value plan-value">${esc(plan)}</div>
        </div>
        ${periodHtml}
        <div class="usage-stat">
          <div class="usage-stat-label">Token Spend</div>
          <div class="usage-stat-value">
            <a href="https://zed.dev/account/billing" target="_blank" class="spend-link" title="View on zed.dev">View on zed.dev ${icons.externalLink}</a>
            <small>limit $${limit}</small>
          </div>
        </div>
      </div>
    </div>
  `
}
