@isTest(SeeAllData=true)
public class WeightRecommendationServiceTest {

    @isTest
    static void testAnalyzeByPolicyName() {
        List<FSL__Scheduling_Policy__c> policies = [
            SELECT Id, Name FROM FSL__Scheduling_Policy__c LIMIT 1
        ];
        if (policies.isEmpty()) {
            System.assert(true, 'No scheduling policies in org — skipping test');
            return;
        }

        WeightRecommendationService.AnalysisInput input = new WeightRecommendationService.AnalysisInput();
        input.schedulingPolicyName = policies[0].Name;

        Test.startTest();
        List<WeightRecommendationService.AnalysisOutput> results =
            WeightRecommendationService.analyzePerformance(new List<WeightRecommendationService.AnalysisInput>{ input });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return one result');
        System.assertEquals(true, results[0].success, 'Analysis should succeed');
        System.assertNotEquals(null, results[0].analysisJson, 'JSON should not be null');
        System.assertEquals(policies[0].Name, results[0].policyName, 'Policy name should match');
    }

    @isTest
    static void testAnalyzeByPolicyId() {
        List<FSL__Scheduling_Policy__c> policies = [
            SELECT Id, Name FROM FSL__Scheduling_Policy__c LIMIT 1
        ];
        if (policies.isEmpty()) {
            System.assert(true, 'No scheduling policies in org — skipping test');
            return;
        }

        WeightRecommendationService.AnalysisInput input = new WeightRecommendationService.AnalysisInput();
        input.schedulingPolicyId = policies[0].Id;

        Test.startTest();
        List<WeightRecommendationService.AnalysisOutput> results =
            WeightRecommendationService.analyzePerformance(new List<WeightRecommendationService.AnalysisInput>{ input });
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'Analysis should succeed');
    }

    @isTest
    static void testAnalyzeWithInvalidName() {
        WeightRecommendationService.AnalysisInput input = new WeightRecommendationService.AnalysisInput();
        input.schedulingPolicyName = 'NonExistent_Policy_XYZ_12345';

        Test.startTest();
        List<WeightRecommendationService.AnalysisOutput> results =
            WeightRecommendationService.analyzePerformance(new List<WeightRecommendationService.AnalysisInput>{ input });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return one result');
        System.assertEquals(false, results[0].success, 'Should fail for nonexistent policy');
        System.assert(results[0].analysisJson.contains('error'), 'Should contain error message');
    }

    @isTest
    static void testAnalyzeWithNoInput() {
        WeightRecommendationService.AnalysisInput input = new WeightRecommendationService.AnalysisInput();

        Test.startTest();
        List<WeightRecommendationService.AnalysisOutput> results =
            WeightRecommendationService.analyzePerformance(new List<WeightRecommendationService.AnalysisInput>{ input });
        Test.stopTest();

        System.assertEquals(false, results[0].success, 'Should fail with no input');
    }

    @isTest
    static void testAnalyzeForLwc() {
        List<FSL__Scheduling_Policy__c> policies = [
            SELECT Id FROM FSL__Scheduling_Policy__c LIMIT 1
        ];
        if (policies.isEmpty()) {
            System.assert(true, 'No scheduling policies in org — skipping test');
            return;
        }

        Test.startTest();
        String resultJson = WeightRecommendationService.analyzeForLwc(policies[0].Id);
        Test.stopTest();

        System.assertNotEquals(null, resultJson, 'Result JSON should not be null');
        System.assert(resultJson.contains('success'), 'Result should contain success field');
    }
}
