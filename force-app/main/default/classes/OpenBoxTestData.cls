/**
 * Test fixtures: users holding the real permission sets, Opportunities created through the
 * direct-edit path, and deterministic integration settings.
 *
 * Setup objects (users, permission assignments) and business records are created in separate
 * System.runAs blocks to avoid mixed-DML errors.
 */
@IsTest
public class OpenBoxTestData {
    public static final String AGENT_USERNAME_PREFIX = 'openbox.agent.';
    public static final String ADMIN_USERNAME_PREFIX = 'openbox.admin.';
    public static final String READ_ONLY_USERNAME_PREFIX = 'openbox.readonly.';
    public static final String OUTSIDER_USERNAME_PREFIX = 'openbox.outsider.';

    public static void useDefaultSettings() {
        OpenBoxSettings.instance = new OpenBoxSettings(
            'OpenBox_Core',
            'Agentforce Sales Agent',
            'AgentforceGovernedAction',
            'salesforce-agentforce',
            10000,
            1,
            5,
            3
        );
    }

    /**
     * Creates the standard cast: an Agentforce agent user, a governance admin and an Opportunity
     * owned by the agent user (so record sharing is never the variable under test).
     */
    public static void createCast() {
        User agent;
        User admin;
        User readOnly;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            createUser(OUTSIDER_USERNAME_PREFIX, standardProfileId());
            agent = createUser(AGENT_USERNAME_PREFIX, standardProfileId());
            admin = createUser(ADMIN_USERNAME_PREFIX, standardProfileId());
            readOnly = createUser(READ_ONLY_USERNAME_PREFIX, minimumAccessProfileId());
            assign(agent.Id, 'OpenBox_Governed_Agent');
            assign(admin.Id, 'OpenBox_Governance_Admin');
            assign(readOnly.Id, createReadOnlyGovernedPermissionSet().Id);
        }
        System.runAs(admin) {
            insert new List<Opportunity>{
                opportunity('Acme renewal', agent.Id, 5, 'Prospecting'),
                opportunity('Globex expansion', readOnly.Id, 5, 'Prospecting')
            };
        }
    }

    public static User agentUser() {
        return userByPrefix(AGENT_USERNAME_PREFIX);
    }

    public static User adminUser() {
        return userByPrefix(ADMIN_USERNAME_PREFIX);
    }

    public static User readOnlyUser() {
        return userByPrefix(READ_ONLY_USERNAME_PREFIX);
    }

    /**
     * A standard user with none of the OpenBox permissions.
     */
    public static User outsiderUser() {
        return userByPrefix(OUTSIDER_USERNAME_PREFIX);
    }

    public static Opportunity opportunityNamed(String name) {
        return [
            SELECT Id, Name, Discount__c, StageName, OwnerId, SystemModstamp
            FROM Opportunity
            WHERE Name = :name
            LIMIT 1
        ];
    }

    public static OpenBoxDiscountGovernance.DiscountRequest request(
        Id opportunityId,
        Decimal discount,
        String justification
    ) {
        OpenBoxDiscountGovernance.DiscountRequest request = new OpenBoxDiscountGovernance.DiscountRequest();
        request.opportunityId = opportunityId;
        request.proposedDiscount = discount;
        request.justification = justification;
        request.userPrompt = 'Give ' + opportunityId + ' a ' + discount + '% discount';
        request.agentSessionId = 'agent-session-test';
        return request;
    }

    public static List<OpenBox_Governed_Request__c> governedRequests() {
        return [
            SELECT
                Id,
                Name,
                Request_Id__c,
                Status__c,
                Decision__c,
                Decision_Id__c,
                Reason__c,
                Justification__c,
                Previous_Discount__c,
                Requested_Discount__c,
                Workflow_Id__c,
                Run_Id__c,
                Activity_Id__c,
                Approval_Expires_At__c,
                Executed_At__c,
                Error__c,
                Next_Event_Sequence__c
            FROM OpenBox_Governed_Request__c
            ORDER BY CreatedDate
        ];
    }

    public static List<String> auditOutcomes() {
        List<String> outcomes = new List<String>();
        for (OpenBox_Governance_Audit__c entry : [
            SELECT Outcome__c
            FROM OpenBox_Governance_Audit__c
            ORDER BY Occurred_At__c, Name
        ]) {
            outcomes.add(entry.Outcome__c);
        }
        return outcomes;
    }

    private static Opportunity opportunity(String name, Id ownerId, Decimal discount, String stage) {
        return new Opportunity(
            Name = name,
            OwnerId = ownerId,
            StageName = stage,
            CloseDate = Date.today().addDays(30),
            Amount = 120000,
            Discount__c = discount,
            Description = 'Primary contact jane.doe@example.com, +1 415 555 0100'
        );
    }

    private static User createUser(String prefix, Id profileId) {
        String unique = prefix + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 10);
        User user = new User(
            Username = unique + '@openbox-governance.test',
            Email = unique + '@openbox-governance.test',
            LastName = prefix.replace('.', ' ').trim(),
            Alias = unique.right(8),
            TimeZoneSidKey = 'GMT',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = profileId
        );
        insert user;
        return user;
    }

    private static void assign(Id userId, String permissionSetName) {
        PermissionSet permissionSet = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName LIMIT 1];
        assign(userId, permissionSet.Id);
    }

    private static void assign(Id userId, Id permissionSetId) {
        insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = permissionSetId);
    }

    /**
     * A permission set with the governed-update entitlement but no Opportunity edit right: the
     * Salesforce side must refuse the write even when OpenBox allows it.
     */
    private static PermissionSet createReadOnlyGovernedPermissionSet() {
        PermissionSet permissionSet = new PermissionSet(
            Name = 'OpenBox_Test_Read_Only',
            Label = 'OpenBox Test Read Only'
        );
        insert permissionSet;
        insert new ObjectPermissions(
            ParentId = permissionSet.Id,
            SobjectType = 'Opportunity',
            PermissionsRead = true,
            PermissionsEdit = false
        );
        List<FieldPermissions> readable = new List<FieldPermissions>();
        for (
            String field : new List<String>{
                'Opportunity.Discount__c',
                'Opportunity.Amount',
                'Opportunity.Description'
            }
        ) {
            readable.add(
                new FieldPermissions(
                    ParentId = permissionSet.Id,
                    SobjectType = 'Opportunity',
                    Field = field,
                    PermissionsRead = true,
                    PermissionsEdit = false
                )
            );
        }
        insert readable;
        CustomPermission governed = [
            SELECT Id
            FROM CustomPermission
            WHERE DeveloperName = :OpenBoxAccess.GOVERNED_PERMISSION
            LIMIT 1
        ];
        insert new SetupEntityAccess(ParentId = permissionSet.Id, SetupEntityId = governed.Id);
        return permissionSet;
    }

    private static User userByPrefix(String prefix) {
        String pattern = prefix + '%';
        return [SELECT Id, Username FROM User WHERE Username LIKE :pattern LIMIT 1];
    }

    private static Id standardProfileId() {
        return [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id;
    }

    private static Id minimumAccessProfileId() {
        List<Profile> profiles = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        return profiles.isEmpty() ? standardProfileId() : profiles[0].Id;
    }
}
