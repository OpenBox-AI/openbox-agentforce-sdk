/**
 * The field guard a customer's trigger calls: only a governed write authorized for that record and
 * field, or a holder of the direct-edit permission, may change a guarded field. Exercised on
 * Opportunity.NextStep with the records a trigger would receive.
 */
@IsTest
private class OpenBoxFieldGuardTest {
    private static final Set<SObjectField> GUARDED = new Set<SObjectField>{ Opportunity.NextStep };

    @IsTest
    static void ungovernedChangeIsRejected() {
        OpenBoxFieldGuard.directEditOverride = false;
        Opportunity before = existing('Send proposal');
        Opportunity after = new Opportunity(Id = before.Id, NextStep = 'Changed');

        OpenBoxFieldGuard.enforce(new List<SObject>{ after }, new Map<Id, SObject>{ before.Id => before }, GUARDED);

        Assert.isTrue(after.hasErrors(), 'an ungoverned change must be rejected');
        Assert.isTrue(after.getErrors()[0].getMessage().contains('OpenBox governed action'), after.getErrors()[0].getMessage());
    }

    @IsTest
    static void caseOnlyChangeIsRejected() {
        OpenBoxFieldGuard.directEditOverride = false;
        Opportunity before = existing('Send proposal');
        Opportunity after = new Opportunity(Id = before.Id, NextStep = 'SEND PROPOSAL');

        OpenBoxFieldGuard.enforce(new List<SObject>{ after }, new Map<Id, SObject>{ before.Id => before }, GUARDED);

        Assert.isTrue(after.hasErrors(), 'a change of letter case is still a change');
    }

    @IsTest
    static void unchangedAndUnguardedFieldsPass() {
        OpenBoxFieldGuard.directEditOverride = false;
        Opportunity before = existing('Send proposal');
        Opportunity after = new Opportunity(Id = before.Id, NextStep = 'Send proposal', Description = 'Edited freely');

        OpenBoxFieldGuard.enforce(new List<SObject>{ after }, new Map<Id, SObject>{ before.Id => before }, GUARDED);

        Assert.isFalse(after.hasErrors());
    }

    @IsTest
    static void insertWithAGuardedValueIsRejected() {
        OpenBoxFieldGuard.directEditOverride = false;
        Opportunity created = new Opportunity(Name = 'New', NextStep = 'Set on create');

        OpenBoxFieldGuard.enforce(new List<SObject>{ created }, null, GUARDED);

        Assert.isTrue(created.hasErrors());
    }

    @IsTest
    static void authorizationCoversOnlyThatRecordAndFieldUntilRevoked() {
        OpenBoxFieldGuard.directEditOverride = false;
        Opportunity before = existing('Send proposal');
        Opportunity other = existing('Other');
        OpenBoxGovernedWriteContext.authorize(before.Id, new Set<String>{ 'nextstep' });

        Opportunity authorized = new Opportunity(Id = before.Id, NextStep = 'Governed');
        Opportunity unauthorized = new Opportunity(Id = other.Id, NextStep = 'Sneaky');
        OpenBoxFieldGuard.enforce(
            new List<SObject>{ authorized, unauthorized },
            new Map<Id, SObject>{ before.Id => before, other.Id => other },
            GUARDED
        );
        Assert.isFalse(authorized.hasErrors(), 'field names are matched case-insensitively');
        Assert.isTrue(unauthorized.hasErrors(), 'authorization is scoped to the record');

        OpenBoxGovernedWriteContext.revokeAll();
        Opportunity later = new Opportunity(Id = before.Id, NextStep = 'Later');
        OpenBoxFieldGuard.enforce(new List<SObject>{ later }, new Map<Id, SObject>{ before.Id => before }, GUARDED);
        Assert.isTrue(later.hasErrors(), 'a revoked authorization never leaks to a later update');
    }

    @IsTest
    static void directEditPermissionExempts() {
        OpenBoxFieldGuard.directEditOverride = true;
        Opportunity before = existing('Send proposal');
        Opportunity after = new Opportunity(Id = before.Id, NextStep = 'Changed by an admin');

        OpenBoxFieldGuard.enforce(new List<SObject>{ after }, new Map<Id, SObject>{ before.Id => before }, GUARDED);

        Assert.isFalse(after.hasErrors());
    }

    @IsTest
    static void withoutTheDirectEditPermissionTheRunningUserIsRefused() {
        Opportunity before = existing('Send proposal');
        Opportunity after = new Opportunity(Id = before.Id, NextStep = 'Changed');

        OpenBoxFieldGuard.enforce(new List<SObject>{ after }, new Map<Id, SObject>{ before.Id => before }, GUARDED, 'No_Such_Permission');

        Assert.isTrue(after.hasErrors(), 'a permission nobody holds exempts nobody');
    }

    /** A record as Trigger.oldMap would hold it; it needs an id, not a database row. */
    private static Opportunity existing(String nextStep) {
        Opportunity record = new Opportunity(Name = 'Guarded ' + nextStep, NextStep = nextStep);
        record.Id = fakeId();
        return record;
    }

    private static Integer counter = 0;

    private static Id fakeId() {
        counter++;
        String suffix = String.valueOf(counter).leftPad(12, '0');
        return Id.valueOf(Opportunity.SObjectType.getDescribe().getKeyPrefix() + suffix);
    }
}
