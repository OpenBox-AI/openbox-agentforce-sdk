// Drives a real conversation with the published, active Agentforce agent through the Salesforce
// CLI's programmatic preview. Actions run live in the org (no simulation).

import { sfJson } from './sf.mjs';

export const AGENT_API_NAME = 'OpenBox_Sales_Agent';

function messagesOf(result) {
  const messages = result?.messages ?? result?.response?.messages ?? [];
  return messages.map((message) => message.message ?? message.text ?? '').filter(Boolean);
}

export class AgentConversation {
  constructor(orgArgs, agentApiName = AGENT_API_NAME) {
    this.orgArgs = orgArgs;
    this.agentApiName = agentApiName;
    this.sessionId = null;
    this.transcript = [];
  }

  start() {
    const { result } = sfJson(['agent', 'preview', 'start', '--api-name', this.agentApiName, ...this.orgArgs]);
    this.sessionId = result.sessionId ?? result.id;
    if (!this.sessionId) throw new Error(`agent preview did not return a session id: ${JSON.stringify(result)}`);
    this.transcript.push({ role: 'agent', text: messagesOf(result).join('\n') });
    return this;
  }

  /** Sends one user turn and returns the agent's reply text. */
  send(utterance) {
    const { result } = sfJson([
      'agent',
      'preview',
      'send',
      '--api-name',
      this.agentApiName,
      '--session-id',
      this.sessionId,
      '--utterance',
      utterance,
      ...this.orgArgs,
    ]);
    const reply = messagesOf(result).join('\n');
    this.transcript.push({ role: 'user', text: utterance }, { role: 'agent', text: reply });
    return reply;
  }

  end() {
    if (!this.sessionId) return;
    try {
      sfJson(['agent', 'preview', 'end', '--api-name', this.agentApiName, '--session-id', this.sessionId, ...this.orgArgs]);
    } finally {
      this.sessionId = null;
    }
  }
}
