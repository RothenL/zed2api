import './style.css'
import { icons } from './icons'
import { renderAccounts } from './pages/accounts'
import { renderHealth } from './pages/health'
import { renderEndpoints } from './pages/endpoints'
import { renderIntegration } from './pages/integration'
import { authHeaders, loginWithToken } from './auth'

const app = document.getElementById('app')!

// Auth gate: the server may be running with AUTH_TOKEN set. Probe an
// authenticated endpoint — a 401 means the server is gated and we lack a valid
// token, so show the login card instead of the app shell.
async function bootstrap() {
  if (!(await isAuthed())) {
    renderLoginCard()
    return
  }
  renderApp()
}

/** Whether this client can reach the gated API right now. */
async function isAuthed(): Promise<boolean> {
  try {
    const r = await fetch('/v1/models', { headers: authHeaders() })
    // 401 => gated and not authed. Anything else (200, or a network failure we
    // catch below) => render the app so the Health page can surface details.
    return r.status !== 401
  } catch {
    return true
  }
}

function renderLoginCard() {
  app.innerHTML = `
    <div class="login-screen">
      <form class="login-card" id="login-form">
        <div class="login-logo"><span>${icons.zap}</span> zed2api</div>
        <p class="login-sub">This server requires a shared access token.</p>
        <label class="login-label" for="login-token">Access token</label>
        <input class="login-input" id="login-token" type="password" autocomplete="off"
               autofocus placeholder="Paste your AUTH_TOKEN" />
        <button class="login-btn" type="submit">Sign in</button>
        <div class="login-err" id="login-err"></div>
        <p class="login-hint">
          The token is stored in an HttpOnly cookie for this browser.<br>
          API clients may instead send <code>Authorization: Bearer &lt;token&gt;</code>
          or <code>x-api-key: &lt;token&gt;</code>.
        </p>
      </form>
    </div>
  `
  const form = document.getElementById('login-form') as HTMLFormElement
  const input = document.getElementById('login-token') as HTMLInputElement
  const err = document.getElementById('login-err')!
  const btn = form.querySelector('button')!
  form.addEventListener('submit', async (e) => {
    e.preventDefault()
    err.textContent = ''
    btn.setAttribute('disabled', '')
    const ok = await loginWithToken(input.value.trim())
    btn.removeAttribute('disabled')
    if (ok) {
      location.reload() // cookie + localStorage now set; render the full app
    } else {
      err.textContent = 'Sign-in failed: wrong token.'
    }
  })
}

function renderApp() {
  app.innerHTML = `
<div class="app">
  <aside class="sidebar">
    <div class="sidebar-header">
      <h1><span class="logo-icon">${icons.zap}</span> zed2api</h1>
      <p>Zed LLM API Proxy</p>
    </div>
    <nav class="sidebar-nav">
      <div class="nav-group">
        <div class="nav-group-label">Manage</div>
        <button class="nav-btn active" data-page="accounts">
          <span class="icon">${icons.users}</span> Accounts
          <span class="badge" id="acc-count">0</span>
        </button>
        <button class="nav-btn" data-page="health">
          <span class="icon">${icons.activity}</span> Health
        </button>
      </div>
      <div class="nav-group">
        <div class="nav-group-label">Reference</div>
        <button class="nav-btn" data-page="endpoints">
          <span class="icon">${icons.globe}</span> Endpoints
        </button>
        <button class="nav-btn" data-page="integration">
          <span class="icon">${icons.code}</span> Integration
        </button>
      </div>
    </nav>
    <div class="sidebar-footer">
      <span class="status-dot"></span> Running on :${location.port || '8000'}
    </div>
  </aside>
  <main class="main-content">
    <div class="page active" id="page-accounts"></div>
    <div class="page" id="page-health"></div>
    <div class="page" id="page-endpoints"></div>
    <div class="page" id="page-integration"></div>
  </main>
</div>
<div class="toast" id="toast"></div>
`

  // Navigation
  document.querySelectorAll<HTMLButtonElement>('.nav-btn[data-page]').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'))
      document.querySelectorAll('.page').forEach(p => p.classList.remove('active'))
      btn.classList.add('active')
      const pageId = btn.dataset.page!
      document.getElementById(`page-${pageId}`)!.classList.add('active')
    })
  })

  // Render pages
  renderAccounts()
  renderHealth()
  renderEndpoints()
  renderIntegration()
}

void bootstrap()
