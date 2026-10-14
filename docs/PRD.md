# PRD — OpenBox Native Governance for Salesforce Agentforce

**Status:** Proposed MVP | **Priority:** P0 | **Target:** Salesforce sandbox proof of concept | **Owner:** OpenBox Integrations

## 1. Goal
Build a **direct Salesforce ↔ OpenBox integration** that lets a Salesforce Agentforce agent execute a **governed custom action**. Before a sensitive Salesforce update, an Apex action calls OpenBox for a policy decision. The operation runs only when authorized; blocked or pending requests must not change Salesforce records.

**Success demo:** Agentforce attempts an Opportunity discount update → OpenBox returns `ALLOW`, `BLOCK`, or `REQUIRE_APPROVAL` → Salesforce enforces the decision and records the result.

## 2. Scope

### In scope (MVP)
- Native Agentforce custom action implemented using Salesforce **Apex `@InvocableMethod`**.
- Direct HTTPS callout from Apex to OpenBox via **Named Credential + External Credential**.
- Governance of **one write operation**: update an Opportunity discount field (`Discount__c`, a demo custom field).
- Configurable policies: allow routine discounts, block forbidden changes, require approval above a threshold.
- Correlation ID, decision ID, and audit of both authorization and final Salesforce execution outcome.
- Salesforce sandbox tests for allow, deny, pending approval, errors, and permission failures.

### Out of scope
- External agent frameworks, middleware gateways, LangChain/CrewAI, and AppExchange publication.
- Universal interception of all native Agentforce actions.
- Broad CRM CRUD support, dashboards, and cross-org policy synchronization.

## 3. User story
As a Salesforce administrator, I want a sensitive Agentforce action checked by OpenBox **before the record changes**, so company policies and human approvals are enforced without leaving Salesforce.

## 4. Architecture

```text
Agentforce (Salesforce)
    → OpenBox_GovernedDiscountUpdate (@InvocableMethod)
    → Apex callout (Named Credential + External Credential)
    → OpenBox policy/authorization service
    ← ALLOW | BLOCK | REQUIRE_APPROVAL + decision_id
    → ALLOW: validate permissions and update Opportunity in Salesforce
    → BLOCK: return denial; no update
    → REQUIRE_APPROVAL: create pending request; no update yet
    → write correlated authorization/execution audit events
```

**Trust boundary:** Only the governed action is protected. Remove equivalent unrestricted write actions from the Agentforce configuration and restrict underlying Salesforce permissions. Agent instructions alone are **not** an enforcement boundary.

## 5. Prerequisites / API contract checkpoint
1. Salesforce sandbox with Agentforce enabled; permission to create Apex, custom actions, custom fields/objects, and credentials.
2. OpenBox tenant, registered agent identity, working policy, and access credentials.
3. **Verify an externally callable synchronous OpenBox authorization API and its actual authentication, response schema, and approval lifecycle.** These details are not established by the public docs. Do **not** assume the sample contract below already exists.
4. If that API does not exist, build or expose a supported OpenBox endpoint **inside OpenBox itself** before proceeding; do not introduce a third-party intermediary.

**Proposed logical request (adapt to actual OpenBox API):**

```json
{
  "request_id": "uuid",
  "agent_id": "agentforce-sales-agent",
  "action": "opportunity.update_discount",
  "salesforce_org_id": "org-id",
  "record_id": "opportunity-id",
  "requested_change": {"Discount__c": 25},
  "actor_id": "authorized-salesforce-principal"
}
```

**Required logical response:** `decision` = `ALLOW` / `BLOCK` / `REQUIRE_APPROVAL` (map from real OpenBox values), plus `decision_id`, `reason`, and `approval_request_id` when relevant. Errors/timeouts are **not** approvals.

## 6. Implementation steps (in order)

1. **Prepare Salesforce:** create sandbox Opportunity sample records and demo `Discount__c`; configure a least-privilege execution identity, permissions, and a test Agentforce agent.
2. **Configure direct authentication:** create an External Credential using an authentication method supported by OpenBox; attach it to a Named Credential pointing to the OpenBox service. Never hardcode tokens in Apex, prompts, or logs.
3. **Create Apex service:** `OpenBoxPolicyClient` serializes the request, performs authenticated HTTPS callout, validates status/schema, and maps decisions to a typed response. Use short timeouts; fail closed for write actions.
4. **Create invocable action:** `OpenBox_GovernedDiscountUpdate` accepts `opportunityId`, `proposedDiscount`, and request context. Validate inputs. **Perform callout before DML**, then branch on decision.
5. **Enforce outcomes:** `ALLOW` → re-read record, check record/object/field access and business constraints, apply write with appropriate Salesforce user-mode/security controls; `BLOCK` → return denial without DML; `REQUIRE_APPROVAL` → persist a pending request without updating the Opportunity.
6. **Approval completion:** approved requests resume in a **separate transaction** via an authenticated, replay-safe mechanism implemented in Salesforce/OpenBox. Re-check approval, expiry, current record state, and permissions before writing. Rejection/expiry results in no update. Never keep an Apex transaction waiting for human review.
7. **Add auditing:** persist `request_id`, `decision_id`, record ID, action, decision, timestamps, and final execution status. Redact sensitive fields and avoid secrets. Record failed writes as failures, not successful approvals.
8. **Wire Agentforce:** in Agentforce Builder, create an action from the `@InvocableMethod`; give it an explicit description and configure the relevant agent topic/subagent to use it for discount changes. Remove other write actions that could bypass governance.
9. **Test and deploy:** add Apex HTTP mock tests and sandbox end-to-end scenarios. Package/deploy Salesforce metadata; credentials/secrets must be provisioned securely per environment.

## 7. Acceptance criteria

| Test | Expected result |
|---|---|
| OpenBox returns `ALLOW` | One authorized update; audit references successful write |
| OpenBox returns `BLOCK` | No Opportunity change; denial returned and audited |
| OpenBox returns `REQUIRE_APPROVAL` | No immediate write; valid pending approval created |
| Approval rejected/expired | No write |
| Approved request replayed | At most one committed mutation |
| OpenBox unavailable/timeout/malformed response | No write; clear error/audit |
| Salesforce permission/field check fails | No write even if OpenBox allows |
| Agent attempts alternate direct update | Test agent cannot bypass governed path |
| Concurrent record edit before approval resolution | Stale request rejected or re-authorized |

**MVP is done when** all the above pass in the sandbox and an Agentforce conversation demonstrates ALLOW, BLOCK, and approval-required paths end to end.

## 8. Delivery plan
- **Week 1:** Confirm OpenBox API; provision sandbox; define policies and auth.
- **Week 2:** Build/test Apex callout, invocable action, and allow/block logic.
- **Week 3:** Add pending approvals, resumed execution, audit, and negative tests.
- **Week 4:** Agentforce wiring, end-to-end demo, access review, and deployment notes.

**Dependencies / blockers:** Real OpenBox synchronous decision API; secure credential provisioning; Agentforce access; correct authorization and approval semantics. Timeline is an estimate, not a commitment.

## 9. Sources / implementation references
- Salesforce custom Apex actions: https://developer.salesforce.com/docs/ai/agentforce/guide/agent-invocablemethod.html
- Salesforce Agentforce action types: https://developer.salesforce.com/docs/ai/agentforce/guide/get-started-actions.html
- Salesforce Named/External Credentials: https://developer.salesforce.com/docs/platform/named-credentials/guide/get-started.html
- OpenBox product docs: https://docs.openbox.ai/
- OpenBox governance overview: https://www.openbox.ai/blog/ai-agents-can-rewrite-their-own-permissions

> **Agent instruction:** First inspect the actual OpenBox API contract and current Salesforce org metadata. Treat example field names and request/response schemas as placeholders. Implement the smallest working governed Agentforce action; do not claim universal Agentforce interception.

## 10. Implementation notes (as built)

The checkpoint in section 5 was resolved against the real OpenBox contract. These notes replace the placeholders there.

- **Authorization API.** OpenBox Core already exposes the synchronous API: `POST /api/v3/governance/evaluate` (decision) and `POST /api/v3/governance/approval` (approval status). No new OpenBox endpoint was needed. Decisions on the wire are `allow`, `require_approval`, `block` and `halt`; `halt` (stop the agent session) was added to the PRD's three outcomes. The decision id is Core's `governance_event_id`. Core does not return an approval id; approvals are addressed by `workflow_id`, `run_id` and `activity_id`.
- **Request shape.** The PRD's logical request is sent as OpenBox governance events in the same wire format as the OpenBox SDKs: a run (`WorkflowStarted` … `WorkflowCompleted`) containing an `OpportunityLookup` activity and an `OpportunityDiscountUpdate` activity, with the SOQL read, locked re-read and DML update reported as started/completed span pairs. Policies, guardrails and behaviour rules evaluate those events.
- **Authentication.** Named Credential `OpenBox_Core` + External Credential `OpenBox_Core_Auth` carry the agent's API key, which Apex never sees. The agent also proves its identity with OpenBox workload identity (contract v3): `OpenBoxWorkloadIdentity` reads `/api/v3/auth/bootstrap`, signs an RS256 client assertion with the Salesforce certificate `OpenBox_Workload` (private key not exportable), exchanges it at the pinned identity issuer for a 5-minute workload token, and sends it as `X-OpenBox-Workload-Token` on every Core call.
- **Post-write audit.** Apex forbids callouts after DML, so events describing the write are committed to an outbox in the same transaction and delivered asynchronously, in order.
- **Approval completion (step 6).** Implemented inside Salesforce: a self-rescheduling Queueable polls OpenBox for decisions (with an hourly schedule as a safety net), and the agent's *Check Discount Approval* action can resolve a request on demand. Execution re-checks approval, expiry, record state and permissions under a row lock; no inbound endpoint is exposed.
- **Trust boundary (step 8).** Beyond removing other write actions, the agent user holds `Discount__c` read-only and a trigger rejects any discount change that does not come from the governed action.
- **Policy ownership.** `scripts/openbox/provision.mjs` creates the policy rules, guardrails and behaviour rules once; after that they are edited in the OpenBox dashboard and the next request follows them, with no Salesforce deploy.
- **Packaging.** `force-app` is the unlocked package `OpenBoxGovernance`. Version 1.0.0 was installed in a fresh Developer scratch org and verified end to end through the agent chat against OpenBox staging. The reference agent (`reference-agent/`) is deployed separately because it names an org-specific agent user.
