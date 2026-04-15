@isTest(SeeAllData=true)
public class WeightSimulationServiceTest {

    @isTest
    static void testSimulateByPolicyId() {
        List<FSL__Scheduling_Policy__c> policies = [
            SELECT Id FROM FSL__Scheduling_Policy__c LIMIT 1
        ];
        if (policies.isEmpty()) {
            System.assert(true, 'No scheduling policies in org — skipping test');
            return;
        }

        Test.startTest();
        WeightSimulationService.SimulationResult result =
            WeightSimulationService.simulate(policies[0].Id);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertNotEquals(null, result.currentScenario, 'Current scenario should not be null');
        System.assert(result.totalSimulations > 0, 'Should have at least one simulation');
    }

    @isTest
    static void testSimulateForLwc() {
        List<FSL__Scheduling_Policy__c> policies = [
            SELECT Id FROM FSL__Scheduling_Policy__c LIMIT 1
        ];
        if (policies.isEmpty()) {
            System.assert(true, 'No scheduling policies in org — skipping test');
            return;
        }

        Test.startTest();
        String resultJson = WeightSimulationService.simulateForLwc(policies[0].Id);
        Test.stopTest();

        System.assertNotEquals(null, resultJson, 'JSON should not be null');
        System.assert(resultJson.contains('currentScenario'), 'Should contain current scenario');
        System.assert(resultJson.contains('topScenarios'), 'Should contain top scenarios');
    }

    @isTest
    static void testInvocableByName() {
        List<FSL__Scheduling_Policy__c> policies = [
            SELECT Id, Name FROM FSL__Scheduling_Policy__c LIMIT 1
        ];
        if (policies.isEmpty()) {
            System.assert(true, 'No scheduling policies in org — skipping test');
            return;
        }

        WeightSimulationService.SimulationInput input = new WeightSimulationService.SimulationInput();
        input.schedulingPolicyIdentifier = policies[0].Name;

        Test.startTest();
        List<WeightSimulationService.SimulationOutput> outputs =
            WeightSimulationService.runSimulation(new List<WeightSimulationService.SimulationInput>{ input });
        Test.stopTest();

        System.assertEquals(1, outputs.size(), 'Should return one result');
        System.assertEquals(true, outputs[0].success, 'Should succeed');
        System.assertNotEquals(null, outputs[0].bestScenarioName, 'Should have best scenario name');
    }

    @isTest
    static void testInvocableWithInvalidName() {
        WeightSimulationService.SimulationInput input = new WeightSimulationService.SimulationInput();
        input.schedulingPolicyIdentifier = 'NonExistent_Policy_XYZ_99999';

        Test.startTest();
        List<WeightSimulationService.SimulationOutput> outputs =
            WeightSimulationService.runSimulation(new List<WeightSimulationService.SimulationInput>{ input });
        Test.stopTest();

        System.assertEquals(1, outputs.size(), 'Should return one result');
        System.assertEquals(false, outputs[0].success, 'Should fail for nonexistent policy');
    }

    @isTest
    static void testScenarioComparison() {
        List<FSL__Scheduling_Policy__c> policies = [
            SELECT Id FROM FSL__Scheduling_Policy__c LIMIT 1
        ];
        if (policies.isEmpty()) {
            System.assert(true, 'No scheduling policies in org — skipping test');
            return;
        }

        Test.startTest();
        WeightSimulationService.SimulationResult result =
            WeightSimulationService.simulate(policies[0].Id);
        Test.stopTest();

        if (result.topScenarios != null && !result.topScenarios.isEmpty()) {
            WeightScenarioAssert(result.topScenarios[0]);
            // Best should score >= current
            System.assert(
                result.bestScenario.compositeScore >= result.currentScenario.compositeScore,
                'Best scenario should score at least as well as current'
            );
        }
    }

    private static void WeightScenarioAssert(WeightSimulationService.WeightScenario ws) {
        System.assertNotEquals(null, ws.name, 'Scenario should have a name');
        System.assertNotEquals(null, ws.weights, 'Scenario should have weights');
        System.assert(!ws.weights.isEmpty(), 'Scenario should have at least one weight entry');
        for (WeightSimulationService.WeightEntry we : ws.weights) {
            System.assert(we.weight >= 1 && we.weight <= 10,
                'Weight should be between 1 and 10, got: ' + we.weight);
        }
    }
}
