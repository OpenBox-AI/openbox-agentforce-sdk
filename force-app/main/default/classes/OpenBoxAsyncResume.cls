/**
 * Restarts a background job chain that reached the queueable stack depth. Scheduled once, about a
 * minute ahead, by OpenBoxAsync; when it fires it removes its own schedule and enqueues the job
 * again as the root of a fresh chain.
 *
 * Developer Edition, trial and scratch orgs cap a queueable chain at five jobs. Without this
 * hand-off an approval granted after the cap was reached would wait for the hourly
 * OpenBoxApprovalPollerSchedule, which can be later than the approval's expiry.
 */
public inherited sharing class OpenBoxAsyncResume implements Schedulable {
    @TestVisible
    private static final String JOB_PREFIX = 'OpenBox chain resume: ';

    private final Queueable job;
    private final String signature;

    @TestVisible
    private OpenBoxAsyncResume(Queueable job, String signature) {
        this.job = job;
        this.signature = signature;
    }

    /**
     * Schedules the job to be enqueued again shortly, unless a resume for the same signature is
     * already waiting. Returns true when a resume is (or already was) scheduled.
     */
    public static Boolean schedule(Queueable job, String signature) {
        String name = jobName(signature);
        if (![SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :name LIMIT 1].isEmpty()) {
            return true;
        }
        if ([SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.JobType = '7'] >= 100) {
            // The org's scheduled-job limit is reached; the hourly safety net still applies.
            return false;
        }
        // A cron expression is read in the running user's time zone, which format() uses too.
        String cron = Datetime.now().addMinutes(1).format('s m H d M \'?\' yyyy');
        try {
            System.schedule(name, cron, new OpenBoxAsyncResume(job, signature));
        } catch (AsyncException e) {
            // Another transaction scheduled the same resume first.
        }
        return true;
    }

    @TestVisible
    private static String jobName(String signature) {
        return JOB_PREFIX + signature;
    }

    public void execute(SchedulableContext context) {
        // A one-off schedule: free its name (and the class, for deployments) before re-enqueuing.
        System.abortJob(context.getTriggerId());
        OpenBoxAsync.enqueueOnce(job, signature, 0);
    }
}
