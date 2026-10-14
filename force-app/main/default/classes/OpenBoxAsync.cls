/**
 * Enqueues the integration's background jobs at most once.
 *
 * Within a transaction a static registry suppresses repeat requests; across transactions a
 * Queueable duplicate signature keeps a second copy from being queued while one is pending. A job
 * is never chained past the platform's queueable stack depth; work it leaves behind is picked up
 * by the next enqueue or by the hourly OpenBoxApprovalPollerSchedule.
 */
public inherited sharing class OpenBoxAsync {
    private static final Integer MAX_DELAY_MINUTES = 10;
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
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs() || atMaximumStackDepth()) {
            return false;
        }
        AsyncOptions options = new AsyncOptions();
        options.DuplicateSignature = QueueableDuplicateSignature.Builder().addString(signature).build();
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
        return AsyncInfo.hasMaxStackDepth() &&
            AsyncInfo.getCurrentQueueableStackDepth() >= AsyncInfo.getMaximumQueueableStackDepth();
    }
}
