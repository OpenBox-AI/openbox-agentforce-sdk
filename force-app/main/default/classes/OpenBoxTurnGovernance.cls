/**
 * Governs each user message of an agent conversation, before the agent reasons about it.
 *
 * The agent runs this deterministically at the start of every turn (Agent Script
 * before_reasoning), so it sees every message whatever the model would do with it. The message
 * goes to OpenBox as SignalReceived "user_prompt", the event the OpenBox SDKs gate the prompt on,
 * and the verdict decides whether the agent may act on it:
 *   ALLOW            the agent continues
 *   BLOCK            the agent refuses this message; the conversation goes on
 *   REQUIRE_APPROVAL the agent refuses this message (a turn cannot wait for a human)
 *   HALT             the agent refuses, and the whole conversation is ended
 * OpenBox unreachable, timed out or answering malformed: refused, never allowed.
 *
 * A message is evaluated once per turn. The gate runs in every subagent the turn passes through,
 * so a repeat of the same message within the turn reuses the stored verdict and only reports the
 * subagent change (signal "subagent_selected").
 */
public without sharing class OpenBoxTurnGovernance {
    public static final String VERDICT_ERROR = 'ERROR';

    @TestVisible
    private static final Integer REPEAT_WINDOW_SECONDS = 120;
    private static final Integer MAX_PROMPT_CHARS = 4000;

    public class Turn {
        public String sessionKey;
        public String userInput;
        public String subagent;
    }

    public class Outcome {
        public String sessionKey;
        public Boolean allowed = false;
        public String verdict;
        public String reason;
        public String message;
        public Integer turn;
    }

    private final OpenBoxSettings settings;
    private final OpenBoxClient client;

    public OpenBoxTurnGovernance() {
        this(OpenBoxSettings.get(), new OpenBoxClient());
    }

    @TestVisible
    private OpenBoxTurnGovernance(OpenBoxSettings settings, OpenBoxClient client) {
        this.settings = settings;
        this.client = client;
    }

    public Outcome govern(Turn turn) {
        OpenBoxAgentSession session = OpenBoxAgentSession.load(turn.sessionKey, true);
        Outcome outcome = new Outcome();
        outcome.sessionKey = session.key();
        outcome.turn = session.record.Turn_Count__c == null ? 0 : session.record.Turn_Count__c.intValue();

        if (session.isHalted()) {
            return refuse(outcome, 'HALT', session.record.Last_Prompt_Reason__c, haltedMessage(null));
        }

        String input = turn.userInput == null ? '' : turn.userInput.trim().abbreviate(MAX_PROMPT_CHARS);
        String hash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(input)));
        // A repeat is the same message seen again within the same, still open turn (the gate runs in
        // every subagent the turn passes through). Once the turn has ended it is a new message.
        Boolean repeat = session.record.Status__c == OpenBoxAgentSession.STATUS_ACTIVE && isRepeat(session.record, hash);
        Boolean subagentChanged =
            String.isNotBlank(turn.subagent) && turn.subagent != session.record.Current_Subagent__c;
        if (repeat && !subagentChanged) {
            return fromStored(outcome, session.record);
        }

        List<OpenBox_Governance_Audit__c> audits = new List<OpenBox_Governance_Audit__c>();
        try {
            OpenBoxGovernedRun run = session.join(client, settings, input);
            // A conversation that was closed and resumes starts a new run, counting from zero.
            outcome.turn = session.record.Turn_Count__c == null ? 0 : session.record.Turn_Count__c.intValue();
            if (run.isHalted()) {
                run.finish(false, null, 'halt', 'Session halted by OpenBox at start');
                session.record.Last_Prompt_Verdict__c = 'HALT';
                audits.add(audit(session, 'Halted', (OpenBoxEvaluationResult) null));
                refuse(outcome, 'HALT', null, haltedMessage(null));
            } else if (repeat || String.isBlank(input)) {
                fromStored(outcome, session.record);
                if (String.isBlank(input) && !repeat) {
                    allow(outcome);
                }
            } else {
                Integer turnNumber = outcome.turn + 1;
                session.record.Turn_Count__c = turnNumber;
                outcome.turn = turnNumber;
                OpenBoxEvaluationResult result = run.decideSignal(
                    OpenBoxEvents.SIGNAL_USER_PROMPT,
                    new List<Object>{ input },
                    signalId(session, turnNumber)
                );
                session.record.Last_Prompt_Hash__c = hash;
                session.record.Last_Prompt_At__c = Datetime.now();
                session.record.Last_Prompt_Verdict__c = result.verdict.name();
                session.record.Last_Prompt_Reason__c = result.reason == null ? null : result.reason.abbreviate(4000);
                apply(outcome, session, run, result, audits);
            }
            if (outcome.allowed && subagentChanged) {
                run.signal(
                    OpenBoxEvents.SIGNAL_SUBAGENT_SELECTED,
                    new List<Object>{ turn.subagent },
                    signalId(session, outcome.turn) + '-' + turn.subagent
                );
                session.record.Current_Subagent__c = turn.subagent.abbreviate(255);
            }
        } catch (OpenBoxException e) {
            // Fail closed. Nothing about this message is stored, so the next attempt asks again.
            session.record.Last_Prompt_Hash__c = null;
            audits.add(audit(session, 'Governance_Unavailable', null, new Map<String, Object>{ 'error' => e.getMessage() }));
            refuse(
                outcome,
                VERDICT_ERROR,
                'OpenBox governance unavailable: ' + e.getMessage(),
                'OpenBox could not check this request, so I can\'t act on it right now. Please try again shortly.'
            );
        }

        List<OpenBox_Event_Outbox__c> outbox = session.saveWithDeferredEvents();
        for (OpenBox_Governance_Audit__c entry : audits) {
            entry.Agent_Session__c = session.record.Id;
        }
        insert audits;
        insert outbox;
        if (!outbox.isEmpty()) {
            OpenBoxOutboxDispatcher.ensureScheduled();
        }
        return outcome;
    }

    /**
     * Closes the turn's OpenBox run once the agent has replied (Agent Script after_reasoning):
     * WorkflowCompleted, with status failed when OpenBox refused the message. A turn that left a call
     * waiting for a human is not closed here; resolving the call closes it. Either way the next
     * message starts a new run. Returns true when WorkflowCompleted was sent (or queued).
     */
    public Boolean endTurn(String sessionKey) {
        OpenBoxAgentSession session = OpenBoxAgentSession.findExisting(sessionKey);
        if (session == null || session.record.Status__c != OpenBoxAgentSession.STATUS_ACTIVE ||
            String.isBlank(session.record.Run_Id__c)) {
            return false;
        }
        OpenBox_Agent_Session__c record = session.record;
        Integer waiting = [
            SELECT COUNT()
            FROM OpenBox_Governed_Request__c
            WHERE
                Agent_Session__c = :record.Id
                AND Run_Id__c = :record.Run_Id__c
                AND Status__c IN :OpenBoxRequestStatus.WAITING
        ];
        Boolean closing = waiting == 0;
        if (closing) {
            OpenBoxGovernedRun run = OpenBoxGovernedRun.attach(
                client,
                session.identity(settings),
                record.Trace_Id__c,
                record.Started_At__c
            );
            Boolean allowed = record.Last_Prompt_Verdict__c == null ||
                record.Last_Prompt_Verdict__c == OpenBoxVerdict.ALLOW.name();
            // This runs before Salesforce sends the reply, so the completion is not sent here: it is
            // queued and delivered by the outbox dispatcher, adding no wait to the reply.
            run.deferRemainingEvents();
            run.endConversation(
                allowed,
                new Map<String, Object>{ 'turn' => record.Turn_Count__c, 'subagent' => record.Current_Subagent__c },
                allowed ? null : 'GovernanceBlocked',
                allowed ? null : record.Last_Prompt_Reason__c
            );
            session.adopt(run);
        }
        // The turn is over: the next message starts a new run.
        record.Status__c = OpenBoxAgentSession.STATUS_CLOSED;
        record.Closed_At__c = Datetime.now();
        List<OpenBox_Event_Outbox__c> outbox = session.saveWithDeferredEvents();
        insert outbox;
        if (!outbox.isEmpty()) {
            OpenBoxOutboxDispatcher.ensureScheduled();
        }
        return closing;
    }

    private static void apply(
        Outcome outcome,
        OpenBoxAgentSession session,
        OpenBoxGovernedRun run,
        OpenBoxEvaluationResult result,
        List<OpenBox_Governance_Audit__c> audits
    ) {
        String reason = String.isBlank(result.reason) ? 'Refused by OpenBox policy' : result.reason;
        switch on result.verdict {
            when ALLOW {
                allow(outcome);
                outcome.verdict = result.verdict.name();
            }
            when HALT {
                session.markHalted();
                run.finish(false, null, 'halt', reason);
                audits.add(audit(session, 'Halted', result));
                refuse(outcome, 'HALT', reason, haltedMessage(reason));
            }
            when REQUIRE_APPROVAL {
                audits.add(audit(session, 'Approval_Required', result));
                refuse(
                    outcome,
                    result.verdict.name(),
                    reason,
                    'This request needs human approval in OpenBox before I can act on it: ' + reason + '.'
                );
            }
            when else {
                audits.add(audit(session, 'Blocked', result));
                refuse(outcome, result.verdict.name(), reason, 'OpenBox blocked this request: ' + reason + '.');
            }
        }
    }

    private static Boolean isRepeat(OpenBox_Agent_Session__c record, String hash) {
        return hash == record.Last_Prompt_Hash__c &&
            record.Last_Prompt_At__c != null &&
            record.Last_Prompt_At__c.addSeconds(REPEAT_WINDOW_SECONDS) > Datetime.now();
    }

    private static Outcome fromStored(Outcome outcome, OpenBox_Agent_Session__c record) {
        String verdict = record.Last_Prompt_Verdict__c;
        if (verdict == OpenBoxVerdict.ALLOW.name()) {
            allow(outcome);
            outcome.verdict = verdict;
            return outcome;
        }
        String reason = String.isBlank(record.Last_Prompt_Reason__c) ? 'Refused by OpenBox policy' : record.Last_Prompt_Reason__c;
        return refuse(outcome, verdict, reason, 'OpenBox blocked this request: ' + reason + '.');
    }

    private static void allow(Outcome outcome) {
        outcome.allowed = true;
        outcome.verdict = OpenBoxVerdict.ALLOW.name();
        outcome.message = null;
    }

    private static Outcome refuse(Outcome outcome, String verdict, String reason, String message) {
        outcome.allowed = false;
        outcome.verdict = verdict;
        outcome.reason = reason;
        outcome.message = message;
        return outcome;
    }

    private static String haltedMessage(String reason) {
        return 'OpenBox ended this conversation' +
            (String.isBlank(reason) ? '' : ': ' + reason) +
            '. Nothing more can be done in it; please start a new conversation.';
    }

    private static String signalId(OpenBoxAgentSession session, Integer turnNumber) {
        return session.record.Run_Id__c + '-sig-' + turnNumber;
    }

    private static OpenBox_Governance_Audit__c audit(
        OpenBoxAgentSession session,
        String outcomeName,
        OpenBoxEvaluationResult result
    ) {
        return audit(session, outcomeName, result, null);
    }

    private static OpenBox_Governance_Audit__c audit(
        OpenBoxAgentSession session,
        String outcomeName,
        OpenBoxEvaluationResult result,
        Map<String, Object> detail
    ) {
        OpenBox_Governance_Audit__c entry = OpenBoxAudit.entry(
            session.key(),
            OpenBoxAudit.STAGE_PROMPT,
            outcomeName,
            result,
            null,
            UserInfo.getUserId(),
            detail
        );
        entry.Action__c = OpenBoxEvents.SIGNAL_USER_PROMPT;
        return entry;
    }
}
