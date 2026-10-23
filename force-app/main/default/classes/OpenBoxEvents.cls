/**
 * Builds OpenBox Core governance event bodies for POST /api/v3/governance/evaluate.
 *
 * The bodies mirror the OpenBox LangGraph SDK lifecycle wire format:
 *  - every event carries source, event_type, workflow_id, run_id, workflow_type, task_queue,
 *    timestamp and an explicit hook_trigger flag;
 *  - the workflow boundary events share activity_id "<run_id>-wf" and the user prompt signal
 *    uses "<run_id>-sig";
 *  - activity_input is always an array, as Core guardrail paths (input.*.field) expect;
 *  - an activity's Started and Completed events share one activity_id; Core keys rows on
 *    (activity_id, event_type), and a refusal on the start is inherited by the completion;
 *  - span-bearing hook events are wire ActivityStarted with hook_trigger=true and exactly one span;
 *  - error payloads are objects {type, message}, never bare strings.
 */
public inherited sharing class OpenBoxEvents {
    public static final String SOURCE = 'workflow-telemetry';

    public static final String WORKFLOW_STARTED = 'WorkflowStarted';
    public static final String WORKFLOW_COMPLETED = 'WorkflowCompleted';
    public static final String WORKFLOW_FAILED = 'WorkflowFailed';
    public static final String SIGNAL_RECEIVED = 'SignalReceived';
    public static final String ACTIVITY_STARTED = 'ActivityStarted';
    public static final String ACTIVITY_COMPLETED = 'ActivityCompleted';

    public static final String STATUS_COMPLETED = 'completed';
    public static final String STATUS_FAILED = 'failed';
    public static final String STATUS_TERMINATED = 'terminated';

    public static final String SIGNAL_USER_PROMPT = 'user_prompt';
    public static final String SIGNAL_SUBAGENT_SELECTED = 'subagent_selected';

    private OpenBoxEvents() {
    }

    /**
     * The identifiers shared by every event of one governed run. Generated once per run and
     * persisted, so a run resumed in a later transaction emits under the same workflow.
     */
    public class Identity {
        public final String workflowId;
        public final String runId;
        public final String workflowType;
        public final String taskQueue;
        public final String agentName;
        public final String sessionId;

        public Identity(
            String workflowId,
            String runId,
            String workflowType,
            String taskQueue,
            String agentName,
            String sessionId
        ) {
            if (String.isBlank(workflowId) || String.isBlank(runId) || String.isBlank(workflowType)) {
                throw new OpenBoxContractException('workflow_id, run_id and workflow_type are required on every event');
            }
            this.workflowId = workflowId;
            this.runId = runId;
            this.workflowType = workflowType;
            this.taskQueue = taskQueue;
            this.agentName = String.isBlank(agentName) ? workflowType : agentName;
            this.sessionId = sessionId;
        }

        public String workflowActivityId() {
            return runId + '-wf';
        }

        public String signalActivityId() {
            return runId + '-sig';
        }
    }

    public static Map<String, Object> workflowStarted(Identity identity, Map<String, Object> input, String goal) {
        Map<String, Object> event = base(identity, WORKFLOW_STARTED, identity.workflowActivityId(), identity.agentName);
        event.put('activity_input', new List<Object>{ input });
        if (String.isNotBlank(goal)) {
            event.put('goal', goal);
        }
        return event;
    }

    public static Map<String, Object> signalReceived(Identity identity, String signalName, List<Object> signalArgs) {
        return signalReceived(identity, signalName, signalArgs, identity.signalActivityId());
    }

    /**
     * A signal with its own activity_id. A conversation receives one signal per user message, and
     * Core keys rows on (activity_id, event_type), so each turn's signal needs a distinct id.
     */
    public static Map<String, Object> signalReceived(
        Identity identity,
        String signalName,
        List<Object> signalArgs,
        String activityId
    ) {
        Map<String, Object> event = base(identity, SIGNAL_RECEIVED, activityId, signalName);
        event.put('signal_name', signalName);
        event.put('signal_args', signalArgs);
        return event;
    }

    public static Map<String, Object> activityStarted(
        Identity identity,
        String activityId,
        String activityType,
        Map<String, Object> input
    ) {
        Map<String, Object> event = base(identity, ACTIVITY_STARTED, activityId, activityType);
        event.put('activity_input', new List<Object>{ input });
        return event;
    }

    /**
     * A span evaluation attached to an activity that already has its plain ActivityStarted row.
     * Core stores the span only when that parent row exists, so callers send activityStarted first.
     */
    public static Map<String, Object> hook(
        Identity identity,
        String activityId,
        String activityType,
        Map<String, Object> spanWire
    ) {
        Map<String, Object> event = base(identity, ACTIVITY_STARTED, activityId, activityType);
        event.put('hook_trigger', true);
        event.put('spans', new List<Object>{ spanWire });
        event.put('span_count', 1);
        return event;
    }

    public static Map<String, Object> activityCompleted(
        Identity identity,
        String activityId,
        String activityType,
        String status,
        Object output,
        Map<String, Object> error,
        Long durationMs
    ) {
        Map<String, Object> event = base(identity, ACTIVITY_COMPLETED, activityId, activityType);
        event.put('status', status);
        event.put('activity_output', output);
        event.put('duration_ms', durationMs);
        if (error != null) {
            event.put('error', error);
        }
        return event;
    }

    public static Map<String, Object> workflowCompleted(
        Identity identity,
        String status,
        Object output,
        Map<String, Object> error,
        Long durationMs
    ) {
        Map<String, Object> event = base(
            identity,
            WORKFLOW_COMPLETED,
            identity.workflowActivityId(),
            identity.agentName
        );
        event.put('status', status);
        event.put('activity_output', output);
        event.put('workflow_output', output);
        event.put('duration_ms', durationMs);
        if (error != null) {
            event.put('error', error);
        }
        return event;
    }

    public static Map<String, Object> workflowFailed(Identity identity, String status, Map<String, Object> error) {
        Map<String, Object> event = base(identity, WORKFLOW_FAILED, identity.workflowActivityId(), identity.agentName);
        event.put('status', status);
        event.put('error', error);
        return event;
    }

    public static Map<String, Object> error(String type, String message) {
        return new Map<String, Object>{ 'type' => type, 'message' => message };
    }

    private static Map<String, Object> base(
        Identity identity,
        String eventType,
        String activityId,
        String activityType
    ) {
        Map<String, Object> event = new Map<String, Object>{
            'source' => SOURCE,
            'event_type' => eventType,
            'workflow_id' => identity.workflowId,
            'run_id' => identity.runId,
            'workflow_type' => identity.workflowType,
            'activity_id' => activityId,
            'activity_type' => activityType,
            'hook_trigger' => false,
            'timestamp' => OpenBoxIds.timestamp()
        };
        if (String.isNotBlank(identity.taskQueue)) {
            event.put('task_queue', identity.taskQueue);
        }
        if (String.isNotBlank(identity.sessionId)) {
            event.put('session_id', identity.sessionId);
        }
        return event;
    }
}
