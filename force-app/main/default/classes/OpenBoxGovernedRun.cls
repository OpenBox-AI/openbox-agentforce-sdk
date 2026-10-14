/**
 * One governed run (an OpenBox workflow session) and the protocol obligations that come with it.
 *
 * Event order is fixed by the OpenBox governance protocol:
 *   WorkflowStarted -> [SignalReceived] -> per activity: ActivityStarted -> hook spans
 *   (started, then completed) -> ActivityCompleted -> WorkflowCompleted | WorkflowFailed
 *
 * Nothing dangles. Every activity this run opened is closed exactly once, on success, failure or
 * refusal, and finish() closes anything still open before the terminal workflow event. After a
 * HALT, Core ends the session and refuses further events, so the run closes with WorkflowFailed
 * (status terminated) and sends nothing else.
 *
 * Decision events (WorkflowStarted, ActivityStarted, started hook spans) are always sent
 * synchronously: their verdict gates the operation, and a failure to obtain one raises.
 * Telemetry events (completed hook spans, ActivityCompleted, the workflow terminal event) never
 * raise. They are sent synchronously while that is still possible, and once deferred (because the
 * transaction has performed DML, after which Apex forbids callouts, or because a send failed)
 * every later event is queued in order for the transactional outbox.
 */
public inherited sharing class OpenBoxGovernedRun {
    public final OpenBoxEvents.Identity identity;
    public final String traceId;
    public final Datetime startedAt;

    private final OpenBoxClient client;
    private final List<Activity> openActivities = new List<Activity>();
    private final List<Map<String, Object>> deferredEvents = new List<Map<String, Object>>();
    private final List<String> telemetryFailures = new List<String>();
    private Boolean dataWritten = false;
    private Boolean deferred = false;
    private Boolean halted = false;
    private Boolean finished = false;

    /**
     * Handle for one governed activity. activityId is shared by its Started and Completed events,
     * by every hook span reported against it, and by the approval poll that resolves it.
     */
    public class Activity {
        public final String activityId;
        public final String activityType;
        public final Datetime startedAt;
        private Boolean closed = false;

        private Activity(String activityId, String activityType, Datetime startedAt) {
            this.activityId = activityId;
            this.activityType = activityType;
            this.startedAt = startedAt;
        }

        public Boolean isClosed() {
            return closed;
        }
    }

    private OpenBoxGovernedRun(
        OpenBoxClient client,
        OpenBoxEvents.Identity identity,
        String traceId,
        Datetime startedAt
    ) {
        this.client = client;
        this.identity = identity;
        this.traceId = traceId;
        this.startedAt = startedAt;
    }

    /**
     * Opens a new run. WorkflowStarted is sent immediately: Core creates the session from it, and
     * without a session no span or approval can be recorded, so a failure here raises.
     */
    public static OpenBoxGovernedRun start(
        OpenBoxClient client,
        OpenBoxEvents.Identity identity,
        Map<String, Object> input,
        String goal
    ) {
        OpenBoxGovernedRun run = new OpenBoxGovernedRun(client, identity, OpenBoxIds.newTraceId(), Datetime.now());
        OpenBoxEvaluationResult result = run.decide(OpenBoxEvents.workflowStarted(identity, input, goal));
        if (result.verdict == OpenBoxVerdict.HALT) {
            run.halted = true;
        }
        return run;
    }

    /**
     * Re-attaches to a run started in an earlier transaction (for example one that waited for a
     * human approval). No event is sent; the session already exists in Core.
     */
    public static OpenBoxGovernedRun resume(
        OpenBoxClient client,
        OpenBoxEvents.Identity identity,
        String traceId,
        Datetime startedAt
    ) {
        return new OpenBoxGovernedRun(client, identity, traceId, startedAt);
    }

    /**
     * Re-attaches to an activity whose ActivityStarted was sent in an earlier transaction.
     */
    public Activity resumeActivity(String activityId, String activityType, Datetime activityStartedAt) {
        Activity activity = new Activity(activityId, activityType, activityStartedAt);
        openActivities.add(activity);
        return activity;
    }

    public void signalUserPrompt(String prompt) {
        if (String.isBlank(prompt) || halted) {
            return;
        }
        emitTelemetry(
            OpenBoxEvents.signalReceived(identity, OpenBoxEvents.SIGNAL_USER_PROMPT, new List<Object>{ prompt })
        );
    }

    public Activity newActivity(String activityType) {
        return new Activity(OpenBoxIds.newRequestId(), activityType, Datetime.now());
    }

    /**
     * Sends ActivityStarted, the event OpenBox policies and input guardrails evaluate. The activity
     * is registered as open only once Core has recorded it, so a failed start never produces an
     * orphan completion.
     */
    public OpenBoxEvaluationResult startActivity(Activity activity, Map<String, Object> input) {
        assertActive();
        OpenBoxEvaluationResult result = decide(
            OpenBoxEvents.activityStarted(identity, activity.activityId, activity.activityType, input)
        );
        openActivities.add(activity);
        recordHalt(result);
        return result;
    }

    /**
     * Reports a span at stage "started", before the operation runs. Behaviour rules evaluate here
     * and can still refuse the operation. A refused operation never runs, so its span is closed
     * immediately as an error carrying the refusal, keeping every span a started/completed pair.
     * After a HALT, Core accepts nothing further and the span is left as Core recorded it.
     */
    public OpenBoxEvaluationResult spanStarted(Activity activity, OpenBoxSpan span) {
        assertActive();
        OpenBoxEvaluationResult result = decide(
            OpenBoxEvents.hook(identity, activity.activityId, activity.activityType, span.toStartedWire())
        );
        recordHalt(result);
        if (!result.isAllowed() && !halted) {
            span.failed('GovernanceRefused', result.summary());
            spanCompleted(activity, span);
        }
        return result;
    }

    /**
     * Reports a span at stage "completed". The operation has already happened; this only records
     * it. The result (null when deferred or unsent) is informational and never undoes anything.
     */
    public OpenBoxEvaluationResult spanCompleted(Activity activity, OpenBoxSpan span) {
        if (halted) {
            return null;
        }
        return emitTelemetry(
            OpenBoxEvents.hook(identity, activity.activityId, activity.activityType, span.toCompletedWire())
        );
    }

    public OpenBoxEvaluationResult completeActivity(Activity activity, Object output) {
        return closeActivity(activity, OpenBoxEvents.STATUS_COMPLETED, output, null);
    }

    public OpenBoxEvaluationResult failActivity(
        Activity activity,
        String errorType,
        String errorMessage,
        Object output
    ) {
        return closeActivity(
            activity,
            OpenBoxEvents.STATUS_FAILED,
            output,
            OpenBoxEvents.error(errorType, errorMessage)
        );
    }

    /**
     * Ends the run. Any activity still open is closed as failed first, so the session never shows
     * an orphaned activity. Idempotent.
     */
    public void finish(Boolean succeeded, Object output, String errorType, String errorMessage) {
        if (finished) {
            return;
        }
        if (halted) {
            terminate(errorMessage);
            return;
        }
        for (Integer i = openActivities.size() - 1; i >= 0; i--) {
            Activity activity = openActivities[i];
            if (!activity.closed) {
                failActivity(activity, 'ActivityAbandoned', 'Run ended before the activity completed', null);
            }
        }
        Map<String, Object> error = succeeded ? null : OpenBoxEvents.error(errorType, errorMessage);
        emitTelemetry(
            OpenBoxEvents.workflowCompleted(
                identity,
                succeeded ? OpenBoxEvents.STATUS_COMPLETED : OpenBoxEvents.STATUS_FAILED,
                output,
                error,
                elapsedMs(startedAt)
            )
        );
        finished = true;
    }

    /**
     * Routes every later event to the outbox. Call immediately before the transaction's first DML.
     */
    public void deferRemainingEvents() {
        dataWritten = true;
        deferred = true;
    }

    public Boolean isHalted() {
        return halted;
    }

    public Boolean isFinished() {
        return finished;
    }

    public List<Map<String, Object>> drainDeferredEvents() {
        List<Map<String, Object>> drained = deferredEvents.clone();
        deferredEvents.clear();
        return drained;
    }

    public List<String> telemetryFailures() {
        return telemetryFailures.clone();
    }

    private OpenBoxEvaluationResult closeActivity(
        Activity activity,
        String status,
        Object output,
        Map<String, Object> error
    ) {
        if (activity.closed) {
            return null;
        }
        activity.closed = true;
        if (halted) {
            return null;
        }
        return emitTelemetry(
            OpenBoxEvents.activityCompleted(
                identity,
                activity.activityId,
                activity.activityType,
                status,
                output,
                error,
                elapsedMs(activity.startedAt)
            )
        );
    }

    private void terminate(String reason) {
        for (Activity activity : openActivities) {
            activity.closed = true;
        }
        emitTelemetry(
            OpenBoxEvents.workflowFailed(
                identity,
                OpenBoxEvents.STATUS_TERMINATED,
                OpenBoxEvents.error('halt', String.isBlank(reason) ? 'Halted by OpenBox verdict' : reason)
            )
        );
        finished = true;
    }

    private OpenBoxEvaluationResult decide(Map<String, Object> event) {
        if (dataWritten) {
            throw new OpenBoxContractException(
                'A governance decision cannot be requested after the transaction has written data'
            );
        }
        deliverBacklog();
        return client.evaluate(event);
    }

    /**
     * Delivers telemetry that failed earlier in this transaction, in order, before the next
     * decision is requested. If Core still cannot take it, the decision fails closed with it.
     */
    private void deliverBacklog() {
        while (!deferredEvents.isEmpty()) {
            client.evaluate(deferredEvents[0]);
            deferredEvents.remove(0);
        }
        deferred = false;
    }

    private OpenBoxEvaluationResult emitTelemetry(Map<String, Object> event) {
        if (deferred) {
            deferredEvents.add(event);
            return null;
        }
        try {
            return client.evaluate(event);
        } catch (OpenBoxException e) {
            telemetryFailures.add(event.get('event_type') + ': ' + e.getMessage());
            // Keep Core's view ordered: this event and everything after it go to the outbox.
            deferred = true;
            deferredEvents.add(event);
            return null;
        }
    }

    private void recordHalt(OpenBoxEvaluationResult result) {
        if (result.verdict == OpenBoxVerdict.HALT) {
            halted = true;
        }
    }

    private void assertActive() {
        if (halted || finished) {
            throw new OpenBoxContractException('The governed run has already ended');
        }
    }

    private static Long elapsedMs(Datetime since) {
        return since == null ? null : Datetime.now().getTime() - since.getTime();
    }
}
