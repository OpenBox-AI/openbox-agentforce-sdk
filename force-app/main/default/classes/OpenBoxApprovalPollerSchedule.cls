/**
 * Hourly safety net for approval polling. Restarts the OpenBoxApprovalPoller chain in case it was
 * ever interrupted (for example by a platform limit), so an approved request is never stranded, and
 * closes agent conversations that went idle (OpenBoxSessionCloser).
 * The platform does not allow one class to be both Queueable and Schedulable, hence this class.
 */
public inherited sharing class OpenBoxApprovalPollerSchedule implements Schedulable {
    @TestVisible
    private static final String JOB_NAME = 'OpenBox approval poller (hourly safety net)';
    private static final String HOURLY_CRON = '0 17 * * * ?';

    /**
     * Installs the hourly schedule. Returns the CronTrigger id; idempotent.
     */
    public static Id install() {
        List<CronTrigger> existing = [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :JOB_NAME LIMIT 1];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }
        return System.schedule(JOB_NAME, HOURLY_CRON, new OpenBoxApprovalPollerSchedule());
    }

    public void execute(SchedulableContext context) {
        OpenBoxApprovalPoller.ensureScheduled();
        OpenBoxSessionCloser.ensureScheduled();
    }
}
