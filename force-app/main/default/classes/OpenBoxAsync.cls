/**
 * Enqueues the integration's background jobs at most once.
 *
 * Within a transaction a static registry suppresses repeat requests; across transactions a
 * Queueable duplicate signature keeps a second copy from being queued while one is pending.
 *
 * Every chain starts with an explicit maximum stack depth of CHAIN_DEPTH. Developer Edition, trial
 * and scratch orgs cap chains at five jobs without reporting it through AsyncInfo, so an implicit
 * cap would go unnoticed and the next enqueue would fail. A job at that depth hands its successor
 * to OpenBoxAsyncResume, which starts a fresh chain about a minute later.
 */
public inherited sharing class OpenBoxAsync {
    private static final Integer MAX_DELAY_MINUTES = 10;
    // The lowest platform cap (Developer Edition, trial and scratch orgs), so it holds in every org.
    @TestVisible
    private static final Integer CHAIN_DEPTH = 5;
    // Apex tests cannot chain queueable jobs; tests that cover the hand-off turn it on.
    @TestVisible
    private static Boolean resumeInTests = false;
    @TestVisible
    private static final Set<String> enqueuedThisTransaction = new Set<String>();

    private OpenBoxAsync() {
    }

    /**
     * @return true when a job was queued by this call.
     */
    public static Boolean enqueueOnce(Queueable job, String signature, Integer delayMinutes) {
        if (enqueuedThisTransaction.contains(signature)) {
            return false;
        }
        if (atMaximumStackDepth()) {
            if (!Test.isRunningTest() || resumeInTests) {
                OpenBoxAsyncResume.schedule(job, signature);
                enqueuedThisTransaction.add(signature);
            }
            return false;
        }
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            return false;
        }
        AsyncOptions options = new AsyncOptions();
        options.DuplicateSignature = QueueableDuplicateSignature.Builder().addString(signature).build();
        if (!System.isQueueable()) {
            options.MaximumQueueableStackDepth = CHAIN_DEPTH;
        }
        Integer delay = delayMinutes == null ? 0 : Math.min(Math.max(delayMinutes, 0), MAX_DELAY_MINUTES);
        if (delay > 0) {
            options.MinimumQueueableDelayInMinutes = delay;
        }
        try {
            System.enqueueJob(job, options);
        } catch (DuplicateMessageException e) {
            // An identical job is already queued and will do this work.
            enqueuedThisTransaction.add(signature);
            return false;
        }
        enqueuedThisTransaction.add(signature);
        return true;
    }

    private static Boolean atMaximumStackDepth() {
        if (!System.isQueueable()) {
            return false;
        }
        // Apex tests cannot chain queueable jobs at all, and AsyncInfo does not report that limit.
        if (Test.isRunningTest()) {
            return true;
        }
        // A chain started before CHAIN_DEPTH was set has no reported maximum; treat it as capped too.
        Integer maximum = AsyncInfo.hasMaxStackDepth() ? AsyncInfo.getMaximumQueueableStackDepth() : CHAIN_DEPTH;
        return AsyncInfo.getCurrentQueueableStackDepth() >= Math.min(maximum, CHAIN_DEPTH);
    }
}
