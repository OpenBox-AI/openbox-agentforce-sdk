@IsTest
private class OpenBox_FindOpportunityTest {
    @TestSetup
    static void setup() {
        OpenBoxTestData.createCast();
    }

    private static OpenBox_FindOpportunity.Result find(String query) {
        OpenBox_FindOpportunity.Request request = new OpenBox_FindOpportunity.Request();
        request.nameQuery = query;
        return OpenBox_FindOpportunity.find(new List<OpenBox_FindOpportunity.Request>{ request })[0];
    }

    @IsTest
    static void singleMatchReturnsRecordId() {
        OpenBox_FindOpportunity.Result result;
        System.runAs(OpenBoxTestData.agentUser()) {
            result = find('Acme');
        }
        Assert.areEqual(1, result.matchCount);
        Assert.areEqual(OpenBoxTestData.opportunityNamed('Acme renewal').Id, result.opportunityId);
        Assert.isTrue(result.matches.contains('discount 5%'), result.matches);
    }

    @IsTest
    static void noMatchAndShortQueryAreExplained() {
        System.runAs(OpenBoxTestData.agentUser()) {
            OpenBox_FindOpportunity.Result none = find('Nonexistent deal');
            Assert.areEqual(0, none.matchCount);
            Assert.isNull(none.opportunityId);
            Assert.isTrue(none.matches.startsWith('No Opportunity matches'));

            OpenBox_FindOpportunity.Result tooShort = find(' a ');
            Assert.areEqual(0, tooShort.matchCount);
            Assert.isTrue(tooShort.matches.contains('at least two characters'));
        }
    }

    @IsTest
    static void wildcardInputIsTreatedLiterally() {
        System.runAs(OpenBoxTestData.agentUser()) {
            Assert.areEqual(0, find('%\'%').matchCount, 'quotes and wildcards cannot widen the query');
        }
    }
}
