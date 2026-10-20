<div align="center">

# OpenBox for Salesforce Agentforce

**Runtime governance for Agentforce agents. OpenBox decides every risky action before Salesforce applies it.**

![Salesforce API](https://img.shields.io/badge/Salesforce%20API-66.0-00A1E0?logo=salesforce&logoColor=white)
![Apex](https://img.shields.io/badge/Apex-native-1798c1)
![Package](https://img.shields.io/badge/package-unlocked%201.0.0-success)
![OpenBox](https://img.shields.io/badge/OpenBox-v3%20governance%20API-6f42c1)
![Node](https://img.shields.io/badge/scripts-Node%2020%2B-339933?logo=node.js&logoColor=white)

</div>

---

The OpenBox SDK for Salesforce, written in Apex and installed in the customer's own org. Every message
an Agentforce agent receives and every tool it calls is decided by OpenBox first, and any record field
can be put behind OpenBox so that the agent changes it only through a governed write. The reference
agent in this repo changes Opportunity discounts that way.
OpenBox answers **`allow`**, **`require_approval`**, **`block`** or **`halt`**; Salesforce enforces the
answer before any record changes, and both sides keep a correlated audit of what happened.

> [!NOTE]
> There is no server to host. Salesforce calls OpenBox directly over HTTPS, and OpenBox never calls
> into Salesforce.

## Contents

- [Highlights](#highlights)
- [Governing the whole conversation](#governing-the-whole-conversation)
- [Governing your own record writes](#governing-your-own-record-writes)
- [Architecture (C4)](#architecture-c4)
- [How it works (sequence diagrams)](#how-it-works-sequence-diagrams)
- [Wire format](#wire-format)
- [Security model](#security-model)
- [Policy](#policy)
- [Repository layout](#repository-layout)
- [Getting started](#getting-started)
- [Packaging](#packaging)
- [Operating it](#operating-it)
- [Testing](#testing)
- [Documentation](#documentation)

## Highlights

| | |
|---|---|
| **One path to the data** | Any field can be guarded: a one-line trigger rejects every change that does not come through an OpenBox governed write (the reference agent guards `Discount__c`) |
| **Four verdicts, enforced** | Allow, require approval, block, halt, enforced in Apex before any write |
| **Fails closed** | No answer, a timeout, a malformed body or an identity failure means no write |
| **No secrets in code** | API key in a Named Credential Apex cannot read; identity proven by a certificate whose private key cannot leave Salesforce |
| **SDK-compatible telemetry** | Events and spans in the same shape as the OpenBox Python and TypeScript SDKs, every *started* paired with its *completed* |
| **Policy without deploys** | Rules, guardrails and behaviour rules are edited in the OpenBox dashboard; the next request follows them |
| **Installable** | Ships as a Salesforce package; tested from a clean install in a fresh Developer org |

## Architecture (C4)

### Level 1: System context

```mermaid
C4Context
  title System context: OpenBox for Salesforce Agentforce

  Person(rep, "Sales rep", "Asks the agent to look up deals and change discounts")
  Person(approver, "Sales-ops approver", "Approves or rejects held requests")

  System(sf, "Salesforce org with Agentforce", "Agent, governed Apex actions, Opportunity data, audit trail")
  System_Ext(openbox, "OpenBox", "Policies, guardrails, behaviour rules, approvals, session audit")

  Rel(rep, sf, "Chats with the agent")
  Rel(sf, openbox, "Decisions and events", "HTTPS")
  Rel(approver, openbox, "Decides held requests", "Dashboard")

  UpdateRelStyle(sf, openbox, $offsetY="-45", $offsetX="-30")
  UpdateLayoutConfig($c4ShapeInRow="2", $c4BoundaryInRow="1")
```

### Level 2: Containers

<sub>C4 notation: blue = container in the org, grey = external system, dashed = boundary.</sub>

```mermaid
flowchart LR
  rep(["<b>Sales rep</b><br/><small>[Person]</small>"]):::person

  subgraph org["Salesforce org (customer org)"]
    direction TB
    agent["<b>OpenBox Sales Agent</b><br/><small>[Container: Agentforce, Agent Script]</small><br/>Runs as a least-privilege agent user"]:::container
    actions["<b>Governed actions</b><br/><small>[Container: Apex @InvocableMethod]</small><br/>Find Opportunity, Update Discount,<br/>Check Discount Approval"]:::container
    sdk["<b>OpenBox Apex SDK</b><br/><small>[Container: Apex]</small><br/>Workload identity, client, governed run,<br/>events, spans, outbox, approval poller"]:::container
    creds["<b>Credentials</b><br/><small>[Container: Named + External Credential, Certificate]</small><br/>API key and signing key, invisible to Apex"]:::container
    opp[("<b>Opportunity</b><br/><small>[Standard object]</small><br/>Discount__c, guarded by a trigger")]:::db
    records[("<b>Governance records</b><br/><small>[Custom objects]</small><br/>Governed Request, Audit, Event Outbox")]:::db
  end

  subgraph ob["OpenBox"]
    direction TB
    identity["<b>Identity</b><br/><small>[Container: Keycloak]</small><br/>Verifies the signed assertion,<br/>issues workload tokens"]:::external
    core["<b>Core</b><br/><small>[Container: Governance API v3]</small><br/>evaluate, approval"]:::external
    dash["<b>Dashboard</b><br/><small>[Container: Web app]</small><br/>Policies, approvals, sessions"]:::external
  end

  approver(["<b>Sales-ops approver</b><br/><small>[Person]</small>"]):::person

  rep -- "Chats" --> agent
  agent -- "Invokes" --> actions
  actions -- "Uses" --> sdk
  sdk -- "Signs and authenticates with" --> creds
  sdk -- "Writes only after allow" --> opp
  sdk -- "Writes" --> records
  sdk -- "Signed JWT for token<br/>[HTTPS]" --> identity
  sdk -- "Events and verdicts<br/>[HTTPS]" --> core
  dash -- "Policies, approvals" --> core
  approver -- "Decides held requests" --> dash

  classDef person fill:#08427b,stroke:#052e56,color:#fff
  classDef container fill:#438dd5,stroke:#2e6295,color:#fff
  classDef db fill:#438dd5,stroke:#2e6295,color:#fff
  classDef external fill:#999999,stroke:#6b6b6b,color:#fff
  style org fill:none,stroke:#444,stroke-dasharray:6 4
  style ob fill:none,stroke:#444,stroke-dasharray:6 4
```

### Level 3: Components of the governed action

<sub>C4 notation: light blue = component, grey = outside the container.</sub>

```mermaid
flowchart TB
  agent(["<b>Agentforce agent</b><br/><small>[Container]</small>"]):::ext
  poller["<b>OpenBoxApprovalPoller</b><br/><small>[Component: Queueable]</small><br/>Resumes approved requests"]:::component

  entry["<b>OpenBox_GovernedDiscountUpdate</b><br/><small>[Reference agent: Invocable]</small><br/>What Agentforce calls; the change is<br/>described by OpportunityDiscountWriter"]:::component

  subgraph action["OpenBox SDK (the package)"]
    direction TB
    gov["<b>OpenBoxToolGovernance</b><br/><small>[Component: Service]</small><br/>Decide phase (callouts only),<br/>then one commit phase (all DML)"]:::component
    guard["<b>OpenBoxFieldGuard</b><br/><small>[Component: trigger helper]</small><br/>Only governed writes change<br/>a guarded field"]:::component
    access["<b>OpenBoxAccess</b><br/><small>[Component]</small><br/>Salesforce permission checks"]:::component
    run["<b>OpenBoxGovernedRun</b><br/><small>[Component]</small><br/>Event order, pairs every<br/>started with its completed"]:::component
    events["<b>OpenBoxEvents, OpenBoxSpan</b><br/><small>[Component: Builders]</small><br/>Exact OpenBox SDK payloads"]:::component
    client["<b>OpenBoxClient</b><br/><small>[Component: HTTP]</small><br/>Retry once, fail closed"]:::component
    wid["<b>OpenBoxWorkloadIdentity</b><br/><small>[Component]</small><br/>Bootstrap, certificate-signed JWT,<br/>cached workload token"]:::component
    outbox["<b>OpenBoxOutbox + Dispatcher</b><br/><small>[Component: Queueable]</small><br/>Post-write events, in order"]:::component
  end

  core["<b>OpenBox Core + Identity</b><br/><small>[External]</small>"]:::ext

  agent -- "Invokes" --> entry
  entry -- "governAll" --> gov
  poller -- "resolve" --> gov
  gov -- "Authorizes the write" --> guard
  gov -- "Checks the user" --> access
  gov -- "Drives" --> run
  gov -- "Stages events" --> outbox
  run -- "Builds payloads" --> events
  run -- "Sends" --> client
  client -- "Gets token" --> wid
  client -- "HTTPS" --> core
  wid -- "HTTPS" --> core
  outbox -- "HTTPS" --> core

  classDef component fill:#85bbf0,stroke:#5d82a8,color:#000
  classDef ext fill:#999999,stroke:#6b6b6b,color:#fff
  style action fill:none,stroke:#444,stroke-dasharray:6 4
```

## Governing the whole conversation

Like the other OpenBox SDKs, the agent reports **every intent** to OpenBox, not only discount changes.
Each user message is one OpenBox run, closed when Salesforce replies; all runs of a conversation share
its `workflow_id` and `session_id`:

| When | Event | Decides? |
|---|---|---|
| A user message arrives | `WorkflowStarted` (goal = the message), then `SignalReceived` `user_prompt` | **Yes**: block or approval refuses the message, halt ends the conversation |
| The agent moves to a subagent | `SignalReceived` `subagent_selected` | No |
| The agent calls any tool | `ActivityStarted`, `activity_type` = tool name, `activity_input` = its arguments | **Yes**: the tool runs only on allow; approval holds it |
| The tool finishes | `ActivityCompleted` with the result or error | Read-only tools: output guardrails apply before the agent sees the result |
| Salesforce replies | `WorkflowCompleted` (status `failed` when OpenBox refused the message), queued so the reply is not delayed | No |

A turn that leaves a call waiting for human approval is not closed by the reply; it is closed when
that call is approved and run, rejected or expires. Turns whose reply never arrives are closed by the
hourly idle sweep.

**How it hooks in.** Every subagent of the agent script (and the router) runs `Govern User Message`
deterministically in `before_reasoning`, with the raw message (`@system_variables.user_input`), so
the model never acts on a message OpenBox has not seen, and `End Turn` in `after_reasoning`, which
closes the run once the reply is ready. The first call mints a conversation key; the
agent keeps it in a variable and passes it to every governed action, which join the same session.

**Governing your own tools.**

- *Record writes:* extend `OpenBoxRecordWriter` (see [Governing your own record writes](#governing-your-own-record-writes)).
  `OpportunityDiscountWriter` in the reference agent is a worked example.
- *Apex:* implement `OpenBoxToolExecutor` and call `OpenBoxToolGovernance.govern(...)` with the
  conversation key, the tool name and its arguments. OpenBox decides before `execute` runs.
  `OpenBox_FindOpportunity` is a worked example.
- *Flows, standard actions, invocable Apex:* register them in `OpenBox_Governed_Tool__mdt` and give the
  agent `Run Governed Tool (OpenBox)`. Only registered, active tools can run. A record writer can be
  registered the same way (target type `record_writer`). The reference agent's flow
  `OpenBox_Log_Opportunity_Note` is registered as `log_opportunity_note`.
- *Approvals:* `Check Approval (OpenBox Governed)` resolves any held call, through the same path the
  background poller uses. An approved Apex tool or record write runs from the poller; an approved
  flow or action runs when the agent checks on it, as the agent's own user, never as the background
  job's user.

## Governing your own record writes

The package carries no business logic. To put a field behind OpenBox, extend `OpenBoxRecordWriter`
and say what is read, what changes and which facts OpenBox policies decide on; the SDK does the rest:

```apex
public with sharing class AccountCreditLimitWriter extends OpenBoxRecordWriter {
    public override SObjectType objectType() { return Account.SObjectType; }
    public override Id recordId(Map<String, Object> input) { return (Id) input.get('account_id'); }
    public override Map<String, Object> changes(Map<String, Object> input) {
        return new Map<String, Object>{ 'Credit_Limit__c' => Decimal.valueOf(String.valueOf(input.get('limit'))) };
    }
    public override List<String> snapshotFields() { return new List<String>{ 'Name', 'Rating', 'Credit_Limit__c' }; }
}
```

```apex
OpenBoxToolGovernance.ToolCall call = new OpenBoxToolGovernance.ToolCall();
call.toolName = 'AccountCreditLimitUpdate';            // the activity_type policies match on
call.writer = AccountCreditLimitWriter.class;
call.input = new Map<String, Object>{ 'account_id' => accountId, 'limit' => 50000 };
call.sessionKey = conversationKey;                     // blank: the write is an OpenBox run of its own
OpenBoxToolGovernance.Result result = new OpenBoxToolGovernance().govern(call);
```

```apex
trigger AccountCreditLimitGuard on Account(before insert, before update) {
    OpenBoxFieldGuard.enforce(Trigger.new, Trigger.oldMap, new Set<SObjectField>{ Account.Credit_Limit__c });
}
```

What every governed write gets, without code of its own:

| Step | What happens |
|---|---|
| Before OpenBox | `validate()`, the requesting user's entitlement (`OpenBox_Governed_Record_Write`, or the writer's own custom permission) and capacity checks |
| Lookup | `<Object>Lookup` activity; the record is read `WITH USER_MODE` under a SELECT span, and output guardrails redact the snapshot before `summary()` reaches the agent |
| Decision | The write activity's `ActivityStarted` carries `facts()`, plus `requested_change`, `justification` and `actor_id` |
| Before the write | Locked re-read (`SELECT ... FOR UPDATE` span), staleness against what was read, `refusal()`, object/field/record access for the requesting user, then an UPDATE span for behaviour rules |
| Write | One system-mode update in the commit phase, authorized past the field guard for that DML only; the outcome reaches OpenBox through the outbox |
| Approval | The request waits as `Pending_Approval` and is applied by the poller or `Check Approval`, after the same checks |

Several calls in one transaction (`governAll`) are all decided before any of them writes.

**What Agentforce does not expose.** Two things the LangChain-based SDKs report have no hook here:
the model's own calls (prompt and completion) and the agent's final reply. Messages Salesforce's own
safety layer refuses before the agent script runs (for example "ignore previous instructions") never
reach OpenBox; they are refused anyway.

## How it works (sequence diagrams)

### A discount request, end to end

```mermaid
sequenceDiagram
  autonumber
  actor Rep as Sales rep
  participant Agent as Agentforce agent
  participant Apex as Governed action (Apex)
  participant Core as OpenBox Core
  participant Opp as Opportunity

  Rep->>Agent: Set Routine Renewal to 10%, loyal renewal
  Agent->>Apex: Find Opportunity, then Update Discount
  Apex->>Apex: Validate input, entitlement, limits
  Apex->>Core: WorkflowStarted, SignalReceived
  Apex->>Core: OpportunityLookup activity and SELECT span
  Apex->>Core: ActivityStarted OpportunityDiscountUpdate
  Core-->>Apex: Verdict

  alt allow
    Apex->>Core: SELECT FOR UPDATE span (locked re-read)
    Apex->>Core: UPDATE span started
    Core-->>Apex: allow (behaviour rules)
    Apex->>Opp: Update Discount__c (commit phase)
    Apex->>Apex: Stage completed events in the outbox
  else require_approval
    Apex->>Apex: Save request as Pending_Approval
  else block or halt
    Apex->>Core: ActivityCompleted, WorkflowFailed
  end

  Apex-->>Agent: status, message, request number
  Agent-->>Rep: Done, or held, or refused, with the reason
```

### Workload identity

```mermaid
sequenceDiagram
  autonumber
  participant Apex as OpenBoxWorkloadIdentity
  participant Cert as Certificate OpenBox_Workload
  participant Core as OpenBox Core
  participant IdP as OpenBox Identity

  Apex->>Core: GET /api/v3/auth/bootstrap (API key via Named Credential)
  Core-->>Apex: client_id, issuer, token_endpoint, kid
  Apex->>Apex: Refuse unless issuer matches the pinned issuer
  Apex->>Cert: Sign RS256 assertion (iss = sub = client_id, 60 s)
  Cert-->>Apex: Signature (private key never leaves Salesforce)
  Apex->>IdP: POST token_endpoint (client_credentials, jwt-bearer)
  IdP-->>Apex: Workload token (5 min)
  Apex->>Core: evaluate with API key and X-OpenBox-Workload-Token
```

### Approval

```mermaid
sequenceDiagram
  autonumber
  actor Approver as Sales-ops approver
  participant Dash as OpenBox dashboard
  participant Core as OpenBox Core
  participant Poller as Approval poller or Check Discount Approval
  participant Apex as OpenBoxToolGovernance
  participant Opp as Opportunity

  Approver->>Dash: Approve request
  Dash->>Core: Record decision
  Poller->>Apex: resolve(request)
  Apex->>Apex: Lock row, must still be Pending_Approval
  Apex->>Core: POST /api/v3/governance/approval
  Core-->>Apex: approved, rejected, expired or pending

  alt approved
    Apex->>Apex: Locked re-read, stale check, access re-check
    Apex->>Opp: Update Discount__c
  else rejected or expired
    Apex->>Apex: Close the request, no write
  else still pending
    Apex->>Apex: Leave it for the next poll
  end
```

### Events after the write (outbox)

```mermaid
sequenceDiagram
  autonumber
  participant Apex as Commit phase
  participant DB as Salesforce database
  participant Disp as OpenBoxOutboxDispatcher
  participant Core as OpenBox Core

  Apex->>DB: Update Opportunity and insert outbox rows (one transaction)
  Note over Apex,DB: Apex cannot call out after DML, so these events wait in the outbox
  Disp->>DB: Read queued rows in sequence order
  Disp->>Core: UPDATE span completed, ActivityCompleted, WorkflowCompleted
  alt delivered
    Disp->>DB: Mark sent
  else OpenBox unavailable
    Disp->>DB: Keep queued, retry later
  end
```

## Wire format

One discount request is one OpenBox run. Events and spans follow the OpenBox SDK wire format (the
LangGraph SDK's lifecycle shapes, the base SDK's flat `SpanData` spans):

```
WorkflowStarted                       goal = the user's request
SignalReceived      user_prompt
ActivityStarted     OpportunityLookup
  span SELECT Opportunity             started → completed
ActivityCompleted   OpportunityLookup output guardrails may redact what the agent sees
ActivityStarted     OpportunityDiscountUpdate   ◄ policy rules and input guardrails decide
  span SELECT Opportunity (FOR UPDATE) started → completed    locked re-read
  span UPDATE Opportunity             started ◄ behaviour rules decide → write → completed
ActivityCompleted   OpportunityDiscountUpdate
WorkflowCompleted | WorkflowFailed
```

- Every `ActivityStarted` is closed by exactly one `ActivityCompleted` with the same `activity_id`,
  on success, failure or refusal. A span refused at `started` is closed as an error. After a `halt`,
  OpenBox closes the session and accepts nothing more.
- Event timestamps are strictly increasing within a transaction, so stored order matches send order.

## Security model

- **The governed write is the only path.** The agent user holds a guarded field read-only, and a
  trigger calling `OpenBoxFieldGuard` rejects any change not authorized by a governed write for that
  record and field (people can be exempted with `OpenBox_Guarded_Field_Direct_Edit`). The reference
  agent guards `Discount__c` with `OpportunityDiscountGuard`. Agent instructions are not relied on.
- **Both systems must agree.** An OpenBox `allow` is followed by Salesforce checks for the
  requesting user: entitlement, object edit, field read, record edit access.
- **Fails closed.** Unreachable OpenBox, timeouts, non-2xx answers, malformed bodies, unknown
  verdicts and identity failures all mean no write. Gateway errors are retried once with the same
  idempotency key.
- **Secrets.** The API key lives in the External Credential, encrypted and injected at callout time.
  The signing key never leaves the Salesforce certificate store. Neither is logged or stored in source.
- **Replay safety.** A request executes only from `Pending_Approval`, under `FOR UPDATE`, and leaves
  that status in the same transaction: at most one committed change per request.
- **Staleness.** If the Opportunity changed while the request waited, it is refused as `Stale`.

## Policy

`scripts/openbox/provision.mjs` creates the agent's controls once. After that they belong to the
OpenBox dashboard and are never overwritten (`--reset-policy` restores the defaults). The highest
matching priority wins; a request matching no rule is allowed.

| Priority | Rule, on `ActivityStarted` of `OpportunityDiscountUpdate` | Decision |
|---:|---|---|
| 100 | `is_closed = true` | 🚫 Block |
| 90 | `proposed_discount ≥ 90` | ⛔ Halt |
| 80 | `proposed_discount > 40` | 🚫 Block |
| 70 | `proposed_discount > 15` | ⏳ Require approval |
| — | no rule matches | ✅ Allow |

Also provisioned: **guardrails** (personal data redaction in the justification and the record
snapshot, a manipulation-phrase tripwire), **behaviour rules** (locked re-read before the write,
sign-off for late-stage deals) and **goal alignment**.

## Repository layout

```
.
├── force-app/                     # the package (OpenBoxGovernance, unlocked)
│   └── main/default/
│       ├── classes/               # Apex SDK, its actions, tests (OpenBoxTestWriter governs NextStep)
│       ├── objects/               # Governed Request, Agent Session, Audit, Event Outbox, Settings (mdt)
│       ├── namedCredentials/      # OpenBox_Core
│       ├── externalCredentials/   # OpenBox_Core_Auth (API key)
│       ├── remoteSiteSettings/    # OpenBox_Identity
│       ├── permissionsets/        # OpenBox_Governed_Agent, OpenBox_Governance_Admin
│       └── customPermissions/     # Governed_Record_Write, Guarded_Field_Direct_Edit
├── reference-agent/               # the worked example; deployed, not packaged
│   └── main/default/
│       ├── aiAuthoringBundles/    # OpenBox_Sales_Agent (Agent Script)
│       ├── classes/               # OpportunityDiscountWriter, the discount, lookup and approval actions, tests
│       ├── triggers/              # OpportunityDiscountGuard (OpenBoxFieldGuard on Discount__c)
│       ├── objects/               # Opportunity.Discount__c
│       ├── flows/, customMetadata/ # OpenBox_Log_Opportunity_Note, registered as log_opportunity_note
│       └── permissionsets/        # OpenBox_Sales_Agent, OpenBox_Sales_Admin
├── config/                        # scratch org definition for the package test org
├── scripts/
│   ├── openbox/                   # provision agent and controls, inspect sessions, approvals
│   ├── salesforce/                # certificate, deploy, endpoints, credential, agent user, org setup;
│   │                              # destructive/ lists components to delete from orgs deployed earlier
│   └── e2e/run-live.mjs           # end-to-end suite against a real org and OpenBox
└── docs/                          # PRD, architecture page, one-pager
```

## Getting started

**Prerequisites:** Node 20+, Salesforce CLI (`npm install -g @salesforce/cli`), an org with Agentforce
enabled, and an OpenBox organisation API key. Every setting is described in [`.env.example`](.env.example).

```bash
# 1. Credentials (never committed)
echo "OPENBOX_ORG_API_KEY=obx_key_..." > .env
sf org login web --alias openbox-dev

# 2. Salesforce certificate; its public key goes to .env for step 3
node scripts/salesforce/workload-certificate.mjs --target-org openbox-dev

# 3. OpenBox: register the agent with that key, attach policy, guardrails, behaviour rules
node scripts/openbox/provision.mjs

# 4. Salesforce: deploy with tests, then credentials, demo data and the poller schedule
node scripts/salesforce/deploy.mjs --target-org openbox-dev
node scripts/salesforce/setup-org.mjs --target-org openbox-dev --skip-deploy

# 5. Agentforce: create the agent user, publish and activate the reference agent
node scripts/salesforce/create-agent-user.mjs --target-org openbox-dev
sf agent publish authoring-bundle --api-name OpenBox_Sales_Agent --target-org openbox-dev --skip-retrieve
sf agent activate --api-name OpenBox_Sales_Agent --target-org openbox-dev
```

> [!IMPORTANT]
> Set `default_agent_user` in `reference-agent/.../OpenBox_Sales_Agent.agent` to the username printed
> by `create-agent-user.mjs` before publishing.

<details>
<summary><b>Other OpenBox environments (staging)</b></summary>

Source points at live OpenBox. Set `OPENBOX_PLATFORM_API_URL` and `OPENBOX_CORE_URL` in `.env`;
`deploy.mjs` then runs `configure-endpoints.mjs`, which asks that Core for its identity issuer and
repoints the Named Credential, the remote site and the pinned issuer in the org only.
</details>

<details>
<summary><b>A second org</b></summary>

Keep its OpenBox agent and key in a separate env file:

```bash
OPENBOX_ENV_FILE=.env.pkg-test OPENBOX_AGENT_NAME="Agentforce Sales Agent (Package Test)" \
  node scripts/openbox/provision.mjs
```

Use the same `OPENBOX_ENV_FILE` for the Salesforce scripts.
</details>

<details>
<summary><b>Settings</b></summary>

The `OpenBox_Settings__mdt` record `Default` holds the Named Credential, agent name, workflow type,
task queue, callout timeout, approval poll interval, per-transaction request limit, outbox retry
attempts, identity issuer and workload certificate name.
</details>

## Packaging

`force-app` is the unlocked package **OpenBoxGovernance**; the Dev Hub is `openbox-dev`.

```bash
# Build a version (runs the Apex tests and the coverage check)
sf package version create --package OpenBoxGovernance --installation-key-bypass --code-coverage \
  --wait 60 --target-dev-hub openbox-dev

# Install into a clean org, as a customer would
sf org create scratch --definition-file config/package-test-scratch-def.json \
  --alias openbox-pkg-test --duration-days 30
sf package install --package <04t version id> --target-org openbox-pkg-test --wait 30 --no-prompt
```

After install, the customer creates the certificate, registers its public key on their OpenBox
agent, stores the agent API key in `OpenBox_Core_Auth`, checks the endpoints, assigns the
permission sets and adds the three actions to their agent. A scratch org needs Einstein and
Agentforce turned on once in Setup, because Salesforce requires a person to accept the terms.

| Version | Subscriber package version | Status |
|---|---|---|
| 1.0.0 | `04tgK000000RkgHQAS` | Installed in a fresh Developer scratch org, verified through the agent chat against OpenBox staging |

> [!TIP]
> An AgentExchange listing needs a managed package under an OpenBox namespace and the Salesforce
> security review.

## Operating it

| Task | How |
|---|---|
| See every governed request | List view or report on `OpenBox_Governed_Request__c` |
| Audit trail | `OpenBox_Governance_Audit__c`, linked to each request |
| Approve or reject | OpenBox dashboard, or `node scripts/openbox/approvals.mjs approve <request-id>` |
| Inspect what OpenBox stored | `node scripts/openbox/inspect-session.mjs <request-id>` |
| Undelivered events | `OpenBox_Event_Outbox__c` with `Status__c` `Queued` or `Failed` |
| Change policy | OpenBox dashboard → the agent → Policy |
| Redeploy | `node scripts/salesforce/deploy.mjs` (pauses and restores the poller schedule) |

## Testing

| Suite | Command | Covers |
|---|---|---|
| Apex | run by `deploy.mjs` and every package version build | Every PRD acceptance criterion against a scripted OpenBox: workload identity, event and span pairing, trust boundary, fail closed, approvals, replay, staleness |
| End to end | `node scripts/e2e/run-live.mjs --target-org openbox-dev` | The deployed action against the OpenBox environment in `.env`; checks the Salesforce outcome, the verdicts OpenBox recorded and the stored session's pairing. Report in `out/e2e-report.json` |

## Documentation

- [`docs/OpenBox-Salesforce-One-Pager.txt`](docs/OpenBox-Salesforce-One-Pager.txt) and [`.docx`](docs/OpenBox-Salesforce-One-Pager.docx): customer one-pager
- [`docs/OpenBox-Salesforce-Architecture.html`](docs/OpenBox-Salesforce-Architecture.html): architecture page
- [`docs/PRD.md`](docs/PRD.md): the original requirements, with as-built implementation notes
