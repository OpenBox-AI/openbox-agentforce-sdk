/**
 * Fixtures for the reference agent's tests: the OpenBox SDK's test cast (OpenBoxTestData), with the
 * reference permission sets assigned and every Opportunity at a 5% discount, set by an
 * administrator through the direct-edit path.
 */
@IsTest
public class OpportunityDiscountTestData {
    public static void createCast() {
        OpenBoxTestData.createCast();
        User admin = OpenBoxTestData.adminUser();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            assign(OpenBoxTestData.agentUser().Id, 'OpenBox_Sales_Agent');
            assign(admin.Id, 'OpenBox_Sales_Admin');
            insert new FieldPermissions(
                ParentId = OpenBoxTestData.readOnlyPermissionSetId(),
                SobjectType = 'Opportunity',
                Field = 'Opportunity.Discount__c',
                PermissionsRead = true,
                PermissionsEdit = false
            );
        }
        System.runAs(admin) {
            List<Opportunity> opportunities = [SELECT Id FROM Opportunity];
            for (Opportunity opportunity : opportunities) {
                opportunity.Discount__c = 5;
            }
            update opportunities;
        }
    }

    public static Opportunity opportunityNamed(String name) {
        return [
            SELECT Id, Name, Discount__c, StageName, OwnerId, SystemModstamp
            FROM Opportunity
            WHERE Name = :name
            LIMIT 1
        ];
    }

    public static OpenBox_GovernedDiscountUpdate.Request request(Id opportunityId, Decimal discount, String justification) {
        OpenBox_GovernedDiscountUpdate.Request request = new OpenBox_GovernedDiscountUpdate.Request();
        request.opportunityId = opportunityId;
        request.proposedDiscount = discount;
        request.justification = justification;
        request.userPrompt = 'Give ' + opportunityId + ' a ' + discount + '% discount';
        request.agentSessionId = 'agent-session-test';
        return request;
    }

    /**
     * A discount request as the authorizing transaction would have left it: decided
     * REQUIRE_APPROVAL, with the run's correlation ids and the baseline recorded and nothing written.
     */
    public static OpenBox_Governed_Request__c pendingRequest(Opportunity opportunity, Decimal discount, Id requestedBy) {
        String requestId = UUID.randomUUID().toString();
        OpenBox_Governed_Request__c record = new OpenBox_Governed_Request__c(
            Request_Id__c = requestId,
            Action__c = OpportunityDiscountWriter.ACTION,
            Tool_Name__c = OpportunityDiscountWriter.TOOL_NAME,
            Tool_Input__c = JSON.serialize(OpportunityDiscountWriter.input(opportunity.Id, discount)),
            Target_Type__c = OpenBoxToolGovernance.TARGET_RECORD_WRITER,
            Target_Name__c = OpportunityDiscountWriter.class.getName(),
            Record_Id__c = opportunity.Id,
            Baseline_Modstamp__c = opportunity.SystemModstamp,
            Baseline_Values__c = JSON.serialize(new Map<String, Object>{ 'Discount__c' => opportunity.Discount__c }),
            Status__c = OpenBoxRequestStatus.PENDING,
            Decision__c = 'REQUIRE_APPROVAL',
            Workflow_Id__c = 'salesforce-' + UserInfo.getOrganizationId() + '-' + requestId,
            Run_Id__c = requestId,
            Activity_Id__c = UUID.randomUUID().toString(),
            Trace_Id__c = OpenBoxIds.newTraceId(),
            Requested_By__c = requestedBy,
            OwnerId = requestedBy,
            Approval_Expires_At__c = Datetime.now().addMinutes(30),
            Next_Event_Sequence__c = 0,
            Poll_Count__c = 0
        );
        insert record;
        return record;
    }

    private static void assign(Id userId, String permissionSetName) {
        insert new PermissionSetAssignment(
            AssigneeId = userId,
            PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName LIMIT 1].Id
        );
    }
}
