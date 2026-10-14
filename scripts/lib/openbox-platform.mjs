// Client for the OpenBox platform (management) API: agents, policies, guardrails, behaviour
// rules, approvals and session logs. Authenticated with the organisation key (obx_key_...).
// The runtime governance API (core) is called by Salesforce, not by these scripts.

const USER_AGENT = 'openbox-salesforce-operator/1.0 (+https://openbox.ai)';

export class PlatformError extends Error {
  constructor(method, path, status, body) {
    super(`${method} ${path} -> HTTP ${status}: ${String(body).slice(0, 600)}`);
    this.status = status;
    this.body = body;
  }
}

/** Rows out of any platform envelope; paginated endpoints nest `data` twice. */
export function rowsOf(payload) {
  let current = payload;
  for (let i = 0; i < 4 && current && !Array.isArray(current); i++) {
    current = current.data ?? current.items;
  }
  return Array.isArray(current) ? current.filter((row) => row && typeof row === 'object') : [];
}

/** `{status, data: X}` -> X. */
export function unwrap(payload) {
  return payload && typeof payload === 'object' && 'status' in payload && 'data' in payload ? payload.data : payload;
}

export class OpenBoxPlatform {
  constructor({ apiKey, baseUrl = 'https://api.openbox.ai', timeoutMs = 60000 }) {
    if (!apiKey) throw new Error('An OpenBox organisation API key is required');
    this.apiKey = apiKey;
    this.baseUrl = baseUrl.replace(/\/$/, '');
    this.timeoutMs = timeoutMs;
  }

  async request(method, path, { body, query } = {}) {
    const url = new URL(this.baseUrl + path);
    for (const [key, value] of Object.entries(query ?? {})) {
      if (value !== undefined && value !== null) url.searchParams.set(key, String(value));
    }
    const response = await fetch(url, {
      method,
      headers: {
        'x-api-key': this.apiKey,
        'X-Openbox-Client': 'openbox-salesforce',
        'User-Agent': USER_AGENT,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    const text = await response.text();
    if (!response.ok) throw new PlatformError(method, path, response.status, text);
    return text ? JSON.parse(text) : {};
  }

  // Agents
  async findAgent(name) {
    const rows = rowsOf(await this.request('GET', '/agent/list', { query: { search: name, page: 0, perPage: 100 } }));
    return rows.find((agent) => agent.agent_name === name) ?? null;
  }
  async getAgent(agentId) {
    return unwrap(await this.request('GET', `/agent/${agentId}`));
  }
  async createAgent(body) {
    return unwrap(await this.request('POST', '/agent/create', { body }));
  }
  async rotateApiKey(agentId) {
    return unwrap(await this.request('POST', `/agent/${agentId}/rotate-api-key`, { body: {} }));
  }
  async setGoalAlignment(agentId, body) {
    return unwrap(await this.request('PUT', `/agent/${agentId}/goal-alignment`, { body }));
  }

  // Controls
  async listPolicyRules(agentId) {
    return rowsOf(await this.request('GET', `/agent/${agentId}/policy-rule`));
  }
  async createPolicyRule(agentId, body) {
    return unwrap(await this.request('POST', `/agent/${agentId}/policy-rule`, { body }));
  }
  async updatePolicyRule(agentId, ruleVersionId, body) {
    return unwrap(await this.request('PUT', `/agent/${agentId}/policy-rule/${ruleVersionId}`, { body }));
  }
  async evaluatePolicyRule(agentId, ruleId, input) {
    return unwrap(await this.request('POST', `/agent/${agentId}/policy-rule/${ruleId}/evaluate`, { body: { input } }));
  }
  async policyDeployment(agentId) {
    return unwrap(await this.request('GET', `/agent/${agentId}/policy-rule-set/deployment`));
  }
  async listGuardrails(agentId) {
    return rowsOf(await this.request('GET', `/agent/${agentId}/guardrails`));
  }
  async createGuardrail(agentId, body) {
    return unwrap(await this.request('POST', `/agent/${agentId}/guardrails`, { body }));
  }
  async listBehaviorRules(agentId) {
    return rowsOf(await this.request('GET', `/agent/${agentId}/behavior-rule`));
  }
  async createBehaviorRule(agentId, body) {
    return unwrap(await this.request('POST', `/agent/${agentId}/behavior-rule`, { body }));
  }

  // Approvals
  async pendingApprovals(agentId) {
    return rowsOf(
      await this.request('GET', `/agent/${agentId}/approvals/pending`, { query: { page: 0, perPage: 100 } }),
    );
  }
  async decideApproval(agentId, eventId, action) {
    return unwrap(
      await this.request('PUT', `/agent/${agentId}/approvals/${eventId}/decide`, { query: { action }, body: {} }),
    );
  }

  // Sessions
  async findSessions(agentId, search, perPage = 20) {
    return rowsOf(await this.request('GET', `/agent/${agentId}/sessions`, { query: { page: 0, perPage, search } }));
  }
  async sessionLogs(agentId, sessionId) {
    return rowsOf(
      await this.request('GET', `/agent/${agentId}/sessions/${sessionId}/logs/chronological`, {
        query: { page: 0, perPage: 500 },
      }),
    );
  }
}
