export interface Account {
  name: string
  user_id: string
  current: boolean
}

export interface AccountsResponse {
  accounts: Account[]
  current: string
}

export interface UsageInfo {
  plan?: string
  monthly_spend_in_cents?: number
  monthly_spending_limit_in_cents?: number
  subscriptionPeriod?: string[]
  githubUserLogin?: string
  // from /client/users/me
  user?: { github_login?: string; name?: string; avatar_url?: string }
  planInfo?: {
    plan?: string
    subscription_period?: { started_at?: string; ended_at?: string }
    usage?: { model_requests?: { used?: number; limit?: { limited?: number } } }
  }
  [key: string]: unknown
}

export async function fetchAccounts(): Promise<AccountsResponse> {
  const r = await fetch('/zed/accounts')
  if (!r.ok) throw new Error(`${r.status}`)
  return r.json()
}

export async function switchAccount(name: string): Promise<void> {
  await fetch('/zed/accounts/switch', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ account: name }),
  })
}

export async function deleteAccount(name: string): Promise<void> {
  const r = await fetch('/zed/accounts/delete', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ account: name }),
  })
  if (!r.ok) throw new Error(`${r.status}`)
}

export interface UploadResult {
  success: boolean
  count: number
  accounts: string[]
}

/**
 * Upload an accounts.json document. Accepts either:
 *   - a File (read as text and wrapped), or
 *   - a raw JSON string containing the accounts object.
 * The server stores it verbatim and reloads the account manager.
 */
export async function uploadAccounts(input: File | string): Promise<UploadResult> {
  let accountsJson: string
  if (typeof input === 'string') {
    accountsJson = input
  } else {
    accountsJson = await input.text()
  }
  // Validate client-side first so we can show a friendly error before uploading.
  try {
    const parsed = JSON.parse(accountsJson)
    if (!parsed || typeof parsed !== 'object' || !('accounts' in parsed)) {
      throw new Error('missing "accounts" field')
    }
    if (!parsed.accounts || typeof parsed.accounts !== 'object' || Object.keys(parsed.accounts).length === 0) {
      throw new Error('"accounts" is empty')
    }
  } catch (e) {
    throw new Error(`Invalid accounts.json: ${e instanceof Error ? e.message : String(e)}`)
  }
  const r = await fetch('/zed/accounts/upload', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ accounts_json: accountsJson }),
  })
  const data = await r.json()
  if (!r.ok) {
    throw new Error(data?.error || `upload failed (${r.status})`)
  }
  return data as UploadResult
}

export async function fetchUsage(): Promise<UsageInfo> {
  const r = await fetch('/zed/usage')
  if (!r.ok) throw new Error(`${r.status}`)
  return r.json()
}

export async function fetchBilling(): Promise<Record<string, unknown>> {
  const r = await fetch('/zed/billing')
  if (!r.ok) throw new Error(`${r.status}`)
  return r.json()
}

export interface ChatMessage {
  role: 'user' | 'assistant' | 'system'
  content: string
}

export async function sendOpenAI(
  model: string,
  messages: ChatMessage[],
  maxTokens = 4096,
): Promise<string> {
  const r = await fetch('/v1/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, messages, max_tokens: maxTokens }),
  })
  const d = await r.json()
  return d.choices?.[0]?.message?.content ?? JSON.stringify(d, null, 2)
}

export async function sendAnthropic(
  model: string,
  messages: ChatMessage[],
  maxTokens = 4096,
): Promise<string> {
  const r = await fetch('/v1/messages', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, messages, max_tokens: maxTokens }),
  })
  const d = await r.json()
  return d.content?.[0]?.text ?? JSON.stringify(d, null, 2)
}
