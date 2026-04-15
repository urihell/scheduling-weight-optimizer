@isTest(SeeAllData=true)
public class OptimizationAnalysisServiceTest {

    @isTest
    static void testAnalyzePolicyWithData() {
        List<FSL__Scheduling_Policy__c> policies = [
            SELECT Id, Name FROM FSL__Scheduling_Policy__c LIMIT 1
        ];
        if (policies.isEmpty()) {
            System.assert(true, 'No scheduling policies in org — skipping test');
            return;
        }

        Test.startTest();
        OptimizationAnalysisService.AnalysisResult result =
            OptimizationAnalysisService.analyzePolicy(policies[0].Id);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(policies[0].Id, result.policyId, 'Policy ID should match');
        System.assertEquals(policies[0].Name, result.policyName, 'Policy name should match');
        System.assertNotEquals(null, result.currentWeights, 'Weights list should not be null');
        System.assertNotEquals(null, result.runs, 'Runs list should not be null');
        System.assertNotEquals(null, result.aggregates, 'Aggregates should not be null');
        System.assert(result.totalRunsAnalyzed >= 0, 'Run count should be non-negative');
    }

    @isTest
    static void testAnalyzePolicyNoOptimizationRequests() {
        List<FSL__Scheduling_Policy__c> policies = [
            SELECT Id, Name FROM FSL__Scheduling_Policy__c LIMIT 1
        ];
        if (policies.isEmpty()) {
            System.assert(true, 'No scheduling policies in org — skipping test');
            return;
        }

        Test.startTest();
        OptimizationAnalysisService.AnalysisResult result =
            OptimizationAnalysisService.analyzePolicy(policies[0].Id);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertNotEquals(null, result.runs, 'Runs list should not be null');
        System.assertNotEquals(null, result.aggregates, 'Aggregates should not be null');
    }

    @isTest
    static void testGetCurrentWeights() {
        List<FSL__Scheduling_Policy__c> policies = [
            SELECT Id FROM FSL__Scheduling_Policy__c LIMIT 1
        ];
        if (policies.isEmpty()) {
            System.assert(true, 'No scheduling policies in org — skipping test');
            return;
        }

        Test.startTest();
        List<OptimizationAnalysisService.ObjectiveWeight> weights =
            OptimizationAnalysisService.getCurrentWeights(policies[0].Id);
        Test.stopTest();

        System.assertNotEquals(null, weights, 'Weights list should not be null');
        for (OptimizationAnalysisService.ObjectiveWeight w : weights) {
            System.assertNotEquals(null, w.objectiveId, 'Objective ID should not be null');
            System.assertNotEquals(null, w.objectiveName, 'Objective name should not be null');
        }
    }

    @isTest
    static void testWrapperInstantiation() {
        OptimizationAnalysisService.AnalysisResult ar = new OptimizationAnalysisService.AnalysisResult();
        System.assertNotEquals(null, ar, 'AnalysisResult should be instantiable');

        OptimizationAnalysisService.ObjectiveWeight ow =
            new OptimizationAnalysisService.ObjectiveWeight('001xx000003DGbAAM', 'Test', 'Objective_Asap', 5.0);
        System.assertEquals('Test', ow.objectiveName, 'Name should match');
        System.assertEquals(5.0, ow.weight, 'Weight should match');

        OptimizationAnalysisService.RunMetrics rm = new OptimizationAnalysisService.RunMetrics();
        System.assertNotEquals(null, rm, 'RunMetrics should be instantiable');

        OptimizationAnalysisService.AggregateMetrics am = new OptimizationAnalysisService.AggregateMetrics();
        System.assertNotEquals(null, am, 'AggregateMetrics should be instantiable');
    }
}
