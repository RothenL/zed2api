const ENDPOINTS = [
  { method: 'POST', path: '/v1/chat/completions', desc: 'OpenAI-compatible chat completions' },
  { method: 'POST', path: '/v1/messages', desc: 'Anthropic native messages API' },
  { method: 'GET', path: '/v1/models', desc: 'List available models' },
  { method: 'GET', path: '/zed/accounts', desc: 'List configured accounts' },
  { method: 'POST', path: '/zed/accounts/switch', desc: 'Switch active account' },
  { method: 'POST', path: '/zed/accounts/upload', desc: 'Upload accounts.json (auth file)' },
  { method: 'POST', path: '/zed/accounts/delete', desc: 'Remove an account' },
  { method: 'GET', path: '/zed/usage', desc: 'Current account usage and plan info' },
  { method: 'POST', path: '/api/event_logging/batch', desc: 'Claude Code event logging (stub)' },
]

export function renderEndpoints() {
  const page = document.getElementById('page-endpoints')!
  page.innerHTML = `
    <div class="page-header">
      <h2>API Endpoints</h2>
      <p>Available routes on this proxy server.</p>
    </div>
    <div class="page-body">
      <div class="endpoint-list">
        ${ENDPOINTS.map(ep => `
          <div class="ep-row">
            <span class="ep-method ${ep.method.toLowerCase()}">${ep.method}</span>
            <span class="ep-path">${ep.path}</span>
            <span class="ep-desc">${ep.desc}</span>
          </div>
        `).join('')}
      </div>
    </div>
  `
}
