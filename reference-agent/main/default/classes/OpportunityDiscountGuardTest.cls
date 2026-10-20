/**
 * The trust boundary (PRD "Agent attempts alternate direct update"): an agent user cannot change
 * Opportunity.Discount__c by any path other than the OpenBox governed action.
 */
@IsTest
private class OpportunityDiscountGuardTest {
    private static final String ACME_NAME = 'Acme renewal';

    @TestSetup
    static void setup() {
        OpportunityDiscountTestData.createCast();
    }

    @IsTest
    static void agentCannotUpdateDiscountInUserMode() {
        Opportunity acme = OpportunityDiscountTestData.opportunityNamed(ACME_NAME);
        System.runAs(OpenBoxTestData.agentUser()) {
            try {
                Database.update(new Opportunity(Id = acme.Id, Discount__c = 60), AccessLevel.USER_MODE);
                Assert.fail('field-level security must stop a direct agent write');
            } catch (DmlException e) {
                Assert.isTrue(e.getMessage().containsIgnoreCase('inaccessible'), e.getMessage());
            }
        }
        Assert.isTrue(OpportunityDiscountTestData.opportunityNamed(ACME_NAME).Discount__c == 5);
    }

    @IsTest
    static void agentCannotUpdateDiscountEvenInSystemModeApex() {
        Opportunity acme = OpportunityDiscountTestData.opportunityNamed(ACME_NAME);
        System.runAs(OpenBoxTestData.agentUser()) {
            Database.SaveResult result = Database.update(new Opportunity(Id = acme.Id, Discount__c = 60), false);
            Assert.isFalse(result.isSuccess(), 'the guard must reject writes that bypass field security');
            Assert.areEqual(
                'Discount can only be changed through an OpenBox governed action.',
                result.getErrors()[0].getMessage()
            );
        }
        Assert.isTrue(OpportunityDiscountTestData.opportunityNamed(ACME_NAME).Discount__c == 5);
    }

    @IsTest
    static void agentCannotCreateOpportunityWithDiscount() {
        System.runAs(OpenBoxTestData.agentUser()) {
            Database.SaveResult result = Database.insert(
                new Opportunity(
                    Name = 'Side door',
                    StageName = 'Prospecting',
                    CloseDate = Date.today(),
                    Discount__c = 40
                ),
                false
            );
            Assert.isFalse(result.isSuccess(), 'creating a pre-discounted record is a bypass too');
        }
    }

    @IsTest
    static void agentMayEditOtherFieldsFreely() {
        Opportunity acme = OpportunityDiscountTestData.opportunityNamed(ACME_NAME);
        System.runAs(OpenBoxTestData.agentUser()) {
            update new Opportunity(Id = acme.Id, Description = 'Next step: send proposal');
        }
        Assert.isTrue(OpportunityDiscountTestData.opportunityNamed(ACME_NAME).Discount__c == 5);
    }

    @IsTest
    static void administratorWithDirectEditPermissionMayEdit() {
        Opportunity acme = OpportunityDiscountTestData.opportunityNamed(ACME_NAME);
        System.runAs(OpenBoxTestData.adminUser()) {
            update new Opportunity(Id = acme.Id, Discount__c = 12);
        }
        Assert.isTrue(OpportunityDiscountTestData.opportunityNamed(ACME_NAME).Discount__c == 12);
    }

    @IsTest
    static void governedAuthorizationIsScopedToTheRecordAndRevoked() {
        Opportunity acme = OpportunityDiscountTestData.opportunityNamed(ACME_NAME);
        System.runAs(OpenBoxTestData.agentUser()) {
            OpenBoxGovernedWriteContext.authorize(acme.Id, new Set<String>{ 'Discount__c' });
            Assert.isTrue(OpenBoxGovernedWriteContext.isAuthorized(acme.Id, 'Discount__c'));
            OpenBoxGovernedWriteContext.revokeAll();
            Database.SaveResult result = Database.update(new Opportunity(Id = acme.Id, Discount__c = 30), false);
            Assert.isFalse(result.isSuccess(), 'a revoked authorization must not linger');
        }
    }
}
