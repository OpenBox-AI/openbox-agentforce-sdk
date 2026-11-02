@IsTest
private class OpenBoxAsyncTest {
    private static final String SIGNATURE = 'OpenBoxAsyncTest.Chained';

    /** A job that, once running, asks for its own successor, as the poller does. */
    public class Chained implements Queueable {
        public void execute(QueueableContext context) {
            OpenBoxAsync.resumeInTests = true;
            OpenBoxAsync.enqueueOnce(new Chained(), SIGNATURE, 0);
            // In a test every async job inside stopTest shares one transaction's statics; in an org
            // the resume runs in a transaction of its own.
            OpenBoxAsync.enqueuedThisTransaction.clear();
        }
    }

    @IsTest
    static void rootEnqueueStartsAChain() {
        Test.startTest();
        Boolean queued = OpenBoxAsync.enqueueOnce(new Chained(), SIGNATURE, 0);
        Boolean again = OpenBoxAsync.enqueueOnce(new Chained(), SIGNATURE, 0);
        Test.stopTest();

        Assert.isTrue(queued, 'the first request queues the job');
        Assert.isFalse(again, 'a second request in the same transaction is suppressed');
    }

    @IsTest
    static void jobAtTheStackDepthHandsOffToAScheduledResume() {
        Test.startTest();
        System.enqueueJob(new Chained());
        // stopTest runs the queued job, then the resume it schedules, which re-enqueues the job.
        Test.stopTest();

        Assert.areEqual(
            2,
            [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable' AND ApexClass.Name = 'OpenBoxAsyncTest'],
            'the capped successor is resumed through a schedule instead of being dropped'
        );
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :OpenBoxAsyncResume.jobName(SIGNATURE)],
            'the resume removed its own schedule'
        );
    }

    @IsTest
    static void aWaitingResumeIsNotScheduledTwice() {
        Test.startTest();
        Boolean first = OpenBoxAsyncResume.schedule(new Chained(), SIGNATURE);
        Boolean second = OpenBoxAsyncResume.schedule(new Chained(), SIGNATURE);
        List<CronTrigger> waiting = [
            SELECT NextFireTime
            FROM CronTrigger
            WHERE CronJobDetail.Name = :OpenBoxAsyncResume.jobName(SIGNATURE)
        ];
        Test.stopTest();

        Assert.isTrue(first && second, 'both report a resume as scheduled');
        Assert.areEqual(1, waiting.size(), 'only one resume is scheduled per signature');
        Assert.isTrue(waiting[0].NextFireTime <= Datetime.now().addMinutes(2), 'the resume fires within about a minute');
    }

    @IsTest
    static void resumeRemovesItsScheduleAndStartsAFreshChain() {
        Test.startTest();
        System.schedule(
            OpenBoxAsyncResume.jobName(SIGNATURE),
            Datetime.now().addMinutes(1).format('s m H d M \'?\' yyyy'),
            new OpenBoxAsyncResume(new Chained(), SIGNATURE)
        );
        Test.stopTest();

        Assert.areEqual(
            0,
            [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :OpenBoxAsyncResume.jobName(SIGNATURE)],
            'the one-off schedule removes itself'
        );
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable' AND ApexClass.Name = 'OpenBoxAsyncTest'],
            'the job is enqueued again as the root of a new chain'
        );
    }
}
