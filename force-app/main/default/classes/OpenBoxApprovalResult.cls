/**
 * Typed view of POST /api/v3/governance/approval.
 *
 * Core reports a pending approval as "require_approval", an approval as "allow", and both a human
 * rejection and an expiry as "halt" (expiry with reason "approval request expired"). Core marks
 * expiry lazily from a scheduler, so an approval past its expiration time is treated as expired
 * here even while Core still reports it pending. A "block" (an approver patching the input) is not
 * applied by this integration and counts as a rejection.
 */
public inherited sharing class OpenBoxApprovalResult {
    public enum State {
        PENDING,
        APPROVED,
        REJECTED,
        EXPIRED
    }

    private static final String EXPIRED_REASON_MARKER = 'expired';

    public final State status;
    public final String reason;
    public final Datetime expiresAt;
    public final String governanceEventId;

    public OpenBoxApprovalResult(Map<String, Object> body, Datetime now) {
        if (body == null) {
            throw new OpenBoxContractException('OpenBox returned an empty approval body');
        }
        Object action = body.get('action');
        if (action == null || String.isBlank(String.valueOf(action))) {
            throw new OpenBoxContractException('OpenBox approval response carried no action');
        }
        this.reason = body.get('reason') == null ? null : String.valueOf(body.get('reason'));
        this.expiresAt = OpenBoxIds.parseTimestamp((String) body.get('approval_expiration_time'));
        this.governanceEventId = body.get('id') == null ? null : String.valueOf(body.get('id'));
        this.status = resolve(String.valueOf(action).trim().toLowerCase(), reason, expiresAt, now);
    }

    public Boolean isTerminal() {
        return status != State.PENDING;
    }

    private static State resolve(String action, String reason, Datetime expiresAt, Datetime now) {
        switch on action {
            when 'allow' {
                return State.APPROVED;
            }
            when 'require_approval' {
                return expiresAt != null && now >= expiresAt ? State.EXPIRED : State.PENDING;
            }
            when 'halt' {
                Boolean expired = reason != null && reason.toLowerCase().contains(EXPIRED_REASON_MARKER);
                return expired ? State.EXPIRED : State.REJECTED;
            }
            when 'block' {
                return State.REJECTED;
            }
            when else {
                throw new OpenBoxContractException('Unsupported OpenBox approval action: ' + action);
            }
        }
    }
}
