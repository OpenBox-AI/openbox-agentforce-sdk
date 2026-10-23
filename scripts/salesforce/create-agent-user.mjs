// Creates the dedicated Agentforce agent user and grants it the OpenBox governed-agent permissions.
//
//   node scripts/salesforce/create-agent-user.mjs [--target-org <alias>]
//
// The user carries the Einstein Agent license (no interactive login), the SDK's OpenBox_Governed_Agent
// permission set and the reference agent's OpenBox_Sales_Agent: it may invoke the governed actions and
// read Opportunity.Discount__c, but it holds no edit right on the field, so OpenBox decides every change.
// Idempotent: an existing agent user is reused. Prints the username for the Agent Script config.

import { loadEnv, saveEnv } from '../lib/env.mjs';
import { runApex, sfJson, targetOrgArgs } from '../lib/sf.mjs';

loadEnv();
const orgArgs = targetOrgArgs(process.argv);
const { result: org } = sfJson(['org', 'display', ...orgArgs]);
const username = `openbox.sales.agent.${org.id.slice(0, 15).toLowerCase()}@agentforce.example`;

const [line] = runApex(
  `String username = '${username}';
List<User> existing = [SELECT Id FROM User WHERE Username = :username LIMIT 1];
User agent;
if (existing.isEmpty()) {
    Profile profile = [SELECT Id FROM Profile WHERE Name = 'Einstein Agent User' LIMIT 1];
    agent = new User(
        Username = username,
        LastName = 'OpenBox Sales Agent',
        Alias = 'obxagent',
        Email = UserInfo.getUserEmail(),
        ProfileId = profile.Id,
        TimeZoneSidKey = 'GMT',
        LocaleSidKey = 'en_US',
        EmailEncodingKey = 'UTF-8',
        LanguageLocaleKey = 'en_US'
    );
    insert agent;
} else {
    agent = existing[0];
}
// The platform's Agentforce service-agent runtime permissions, as Setup grants them to agent users.
PermissionSetLicense agentLicense = [SELECT Id FROM PermissionSetLicense WHERE DeveloperName = 'AgentforceServiceAgentUserPsl' LIMIT 1];
if ([SELECT COUNT() FROM PermissionSetLicenseAssign WHERE AssigneeId = :agent.Id AND PermissionSetLicenseId = :agentLicense.Id] == 0) {
    insert new PermissionSetLicenseAssign(AssigneeId = agent.Id, PermissionSetLicenseId = agentLicense.Id);
}
List<PermissionSetAssignment> grants = new List<PermissionSetAssignment>();
for (PermissionSetGroup runtimeGroup : [SELECT Id FROM PermissionSetGroup WHERE DeveloperName = 'AgentforceServiceAgentUserPsg']) {
    if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :agent.Id AND PermissionSetGroupId = :runtimeGroup.Id] == 0) {
        grants.add(new PermissionSetAssignment(AssigneeId = agent.Id, PermissionSetGroupId = runtimeGroup.Id));
    }
}
for (PermissionSet governed : [SELECT Id FROM PermissionSet WHERE Name IN ('OpenBox_Governed_Agent', 'OpenBox_Sales_Agent')]) {
    if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :agent.Id AND PermissionSetId = :governed.Id] == 0) {
        grants.add(new PermissionSetAssignment(AssigneeId = agent.Id, PermissionSetId = governed.Id));
    }
}
insert grants;
System.debug(LoggingLevel.ERROR, 'OBX|' + JSON.serialize(new Map<String, Object>{ 'id' => agent.Id, 'username' => username, 'created' => existing.isEmpty() }));`,
  orgArgs,
);
const agent = JSON.parse(line);
saveEnv({ SF_AGENT_USERNAME: agent.username });
console.log(`agent user ${agent.created ? 'created' : 'exists'}: ${agent.username} (${agent.id}); Agentforce service-agent runtime, OpenBox_Governed_Agent and OpenBox_Sales_Agent assigned`);
