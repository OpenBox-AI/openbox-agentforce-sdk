/**
 * One agent conversation and the OpenBox runs it produces.
 *
 * Each turn (one user message and everything the agent does about it) is one OpenBox run, the way
 * the other OpenBox SDKs report an agent invocation: WorkflowStarted with the message as the goal,
 * SignalReceived "user_prompt", an activity per tool call, and WorkflowCompleted once the agent has
 * replied (OpenBoxTurnGovernance.endTurn, run from Agent Script after_reasoning). All runs of a
 * conversation share its workflow_id and session_id. A turn that left a call waiting for a human
 * stays open until that call is resolved, and is closed then.
 *
 * Agentforce runs each action in its own transaction, so the session lives in an
 * OpenBox_Agent_Session__c row keyed by a conversation key. The first governed call of a
 * conversation mints the key and returns it; the agent keeps it in a variable and passes it to
 * every later call. A conversation OpenBox halted stays halted: later calls are refused without
 * contacting OpenBox. One that went idle and was closed starts a new run when it resumes.
 *
 * Runs without sharing: the session row is integration state, written on behalf of the agent and
 * read by background jobs. It holds correlation ids and verdicts, not business data.
 */
public without sharing class OpenBoxAgentSession {
    public static final String STATUS_ACTIVE = 'Active';
    public static final String STATUS_HALTED = 'Halted';
    public static final String STATUS_CLOSED = 'Closed';

    private static final String WORKFLOW_PREFIX = 'salesforce-conversation-';
    private static final Integer MAX_GOAL_CHARS = 4000;

    public final OpenBox_Agent_Session__c record;
    public OpenBoxGovernedRun run { get; private set; }

    private final Boolean persisted;

    private OpenBoxAgentSession(OpenBox_Agent_Session__c record, Boolean persisted) {
        this.record = record;
        this.persisted = persisted;
    }

    /**
     * The conversation for a key, or a new one (not yet saved) when the key is blank or unknown.
     * lock = true reads the row FOR UPDATE, so concurrent calls of one conversation take turns.
     */
    public static OpenBoxAgentSession load(String sessionKey, Boolean lock) {
        if (String.isNotBlank(sessionKey)) {
            String key = sessionKey.trim();
            List<OpenBox_Agent_Session__c> rows = lock
                ? [
                      SELECT
                          Id,
                          Name,
                          Session_Key__c,
                          Workflow_Id__c,
                          Run_Id__c,
                          Trace_Id__c,
                          Status__c,
                          Turn_Count__c,
                          Current_Subagent__c,
                          Goal__c,
                          Last_Prompt_Hash__c,
                          Last_Prompt_At__c,
                          Last_Prompt_Verdict__c,
                          Last_Prompt_Reason__c,
                          Started_At__c,
                          Last_Activity_At__c,
                          Next_Event_Sequence__c,
                          Requested_By__c
                      FROM OpenBox_Agent_Session__c
                      WHERE Session_Key__c = :key
                      LIMIT 1
                      FOR UPDATE
                  ]
                : [
                      SELECT
                          Id,
                          Name,
                          Session_Key__c,
                          Workflow_Id__c,
                          Run_Id__c,
                          Trace_Id__c,
                          Status__c,
                          Turn_Count__c,
                          Current_Subagent__c,
                          Goal__c,
                          Last_Prompt_Hash__c,
                          Last_Prompt_At__c,
                          Last_Prompt_Verdict__c,
                          Last_Prompt_Reason__c,
                          Started_At__c,
                          Last_Activity_At__c,
                          Next_Event_Sequence__c,
                          Requested_By__c
                      FROM OpenBox_Agent_Session__c
                      WHERE Session_Key__c = :key
                      LIMIT 1
                  ];
            if (!rows.isEmpty()) {
                return new OpenBoxAgentSession(rows[0], true);
            }
        }
        String key = OpenBoxIds.newRequestId();
        OpenBox_Agent_Session__c fresh = new OpenBox_Agent_Session__c(
            Session_Key__c = key,
            Workflow_Id__c = WORKFLOW_PREFIX + UserInfo.getOrganizationId() + '-' + key,
            Status__c = STATUS_ACTIVE,
            Turn_Count__c = 0,
            Next_Event_Sequence__c = 0,
            Requested_By__c = UserInfo.getUserId()
        );
        return new OpenBoxAgentSession(fresh, false);
    }

    /**
     * The existing conversation for a key, locked, or null when there is none. For actions that
     * join a conversation when they are part of one and run on their own otherwise.
     */
    public static OpenBoxAgentSession findExisting(String sessionKey) {
        if (String.isBlank(sessionKey)) {
            return null;
        }
        OpenBoxAgentSession session = load(sessionKey, true);
        return session.persisted ? session : null;
    }

    public String key() {
        return record.Session_Key__c;
    }

    public Boolean isHalted() {
        return record.Status__c == STATUS_HALTED;
    }

    /**
     * Joins the conversation's OpenBox run, starting it first when the conversation is new (or was
     * closed after going idle): WorkflowStarted is sent with the goal, and a HALT on it halts the
     * conversation. Raises OpenBoxException when OpenBox cannot be reached.
     */
    public OpenBoxGovernedRun join(OpenBoxClient client, OpenBoxSettings settings, String goal) {
        if (run != null) {
            return run;
        }
        Boolean starting = !persisted || record.Status__c == STATUS_CLOSED || String.isBlank(record.Run_Id__c);
        if (starting) {
            // The row changes only once Core has the run: if WorkflowStarted fails, the next call
            // starts the run again instead of joining one Core never saw.
            String runId = OpenBoxIds.newRequestId();
            String trimmedGoal = goal == null ? null : goal.abbreviate(MAX_GOAL_CHARS);
            run = OpenBoxGovernedRun.startConversation(
                client,
                new OpenBoxEvents.Identity(
                    record.Workflow_Id__c,
                    runId,
                    settings.workflowType,
                    settings.taskQueue,
                    settings.agentName,
                    record.Session_Key__c
                ),
                new Map<String, Object>{
                    'salesforce_org_id' => UserInfo.getOrganizationId(),
                    'conversation_key' => record.Session_Key__c,
                    'actor_id' => UserInfo.getUserId()
                },
                trimmedGoal
            );
            record.Run_Id__c = runId;
            record.Status__c = STATUS_ACTIVE;
            record.Started_At__c = run.startedAt;
            record.Closed_At__c = null;
            record.Turn_Count__c = 0;
            record.Goal__c = trimmedGoal;
            record.Trace_Id__c = run.traceId;
            if (run.isHalted()) {
                markHalted();
            }
        } else {
            run = OpenBoxGovernedRun.attach(client, identity(settings), record.Trace_Id__c, record.Started_At__c);
        }
        record.Last_Activity_At__c = Datetime.now();
        return run;
    }

    public OpenBoxEvents.Identity identity(OpenBoxSettings settings) {
        return new OpenBoxEvents.Identity(
            record.Workflow_Id__c,
            record.Run_Id__c,
            settings.workflowType,
            settings.taskQueue,
            settings.agentName,
            record.Session_Key__c
        );
    }

    /** Uses a run built elsewhere (for example one closing the turn) as this conversation's run. */
    public void adopt(OpenBoxGovernedRun existing) {
        run = existing;
    }

    /** Marks the conversation halted; every later call is refused without contacting OpenBox. */
    public void markHalted() {
        record.Status__c = STATUS_HALTED;
        record.Closed_At__c = Datetime.now();
    }

    /**
     * Whether a turn's OpenBox run can be closed now that one of its calls has been resolved: the
     * turn itself is over (the conversation has moved on to another run or was closed) and no other
     * call of that run is still waiting for a human.
     */
    public static Boolean runIsOver(Id sessionId, String runId, Set<Id> resolvedRequestIds) {
        if (sessionId == null || String.isBlank(runId)) {
            return false;
        }
        List<OpenBox_Agent_Session__c> sessions = [
            SELECT Run_Id__c, Status__c
            FROM OpenBox_Agent_Session__c
            WHERE Id = :sessionId
            LIMIT 1
        ];
        if (sessions.isEmpty()) {
            return false;
        }
        Boolean turnOver = sessions[0].Run_Id__c != runId || sessions[0].Status__c != STATUS_ACTIVE;
        Integer stillWaiting = [
            SELECT COUNT()
            FROM OpenBox_Governed_Request__c
            WHERE
                Agent_Session__c = :sessionId
                AND Run_Id__c = :runId
                AND Id NOT IN :resolvedRequestIds
                AND Status__c IN :OpenBoxRequestStatus.WAITING
        ];
        return turnOver && stillWaiting == 0 && sessions[0].Status__c != STATUS_HALTED;
    }

    /** Inserts or updates the row. Call in the commit phase, before staging rows that reference it. */
    public void save() {
        record.Last_Activity_At__c = Datetime.now();
        upsert record;
    }

    /**
     * Saves the conversation and stages its own deferred events (those not tied to a tool call) in
     * the outbox. Returns the staged rows for the caller to insert with its other writes.
     */
    public List<OpenBox_Event_Outbox__c> saveWithDeferredEvents() {
        save();
        if (run == null) {
            return new List<OpenBox_Event_Outbox__c>();
        }
        List<OpenBox_Event_Outbox__c> rows = OpenBoxOutbox.stage(record, run.drainDeferredEvents());
        if (!rows.isEmpty()) {
            update record;
        }
        return rows;
    }
}
