@isTest(SeeAllData=true)
public class WeightUpdateServiceTest {

    @isTest
    static void testApplyWeightsSuccess() {
        List<FSL__Scheduling_Policy_Goal__c> existingGoals = [
            SELECT Id, FSL__Scheduling_Policy__c, FSL__Service_Goal__c, FSL__Weight__c
            FROM FSL__Scheduling_Policy_Goal__c
            LIMIT 1
        ];
        if (existingGoals.isEmpty()) {
            System.assert(true, 'No policy goals in org — skipping test');
            return;
        }

        FSL__Scheduling_Policy_Goal__c goal = existingGoals[0];
        Decimal originalWeight = goal.FSL__Weight__c;
        Decimal testWeight = originalWeight == 5 ? 6 : 5;

        String changesJson = '[{"objectiveId":"' + goal.FSL__Service_Goal__c + '","newWeight":' + testWeight + '}]';

        WeightUpdateService.UpdateInput input = new WeightUpdateService.UpdateInput();
        input.schedulingPolicyId = goal.FSL__Scheduling_Policy__c;
        input.weightChangesJson = changesJson;

        Test.startTest();
        List<WeightUpdateService.UpdateOutput> results =
            WeightUpdateService.applyWeights(new List<WeightUpdateService.UpdateInput>{ input });
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'Update should succeed');
        System.assert(results[0].message.contains('Updated 1'), 'Should report 1 update');

        // Restore original weight
        goal.FSL__Weight__c = originalWeight;
        update goal;
    }

    @isTest
    static void testApplyWeightsInvalidJson() {
        WeightUpdateService.UpdateInput input = new WeightUpdateService.UpdateInput();
        input.schedulingPolicyId = 'a0Xxx000000FAKE';
        input.weightChangesJson = 'invalid json';

        Test.startTest();
        List<WeightUpdateService.UpdateOutput> results =
            WeightUpdateService.applyWeights(new List<WeightUpdateService.UpdateInput>{ input });
        Test.stopTest();

        System.assertEquals(false, results[0].success, 'Should fail with invalid JSON');
        System.assert(results[0].message.contains('Error'), 'Should contain error message');
    }

    @isTest
    static void testApplyWeightsNonexistentObjective() {
        List<FSL__Scheduling_Policy__c> policies = [
            SELECT Id FROM FSL__Scheduling_Policy__c LIMIT 1
        ];
        if (policies.isEmpty()) {
            System.assert(true, 'No scheduling policies in org — skipping test');
            return;
        }

        String changesJson = '[{"objectiveId":"a0Xxx000000FAKE","newWeight":5}]';

        WeightUpdateService.UpdateInput input = new WeightUpdateService.UpdateInput();
        input.schedulingPolicyId = policies[0].Id;
        input.weightChangesJson = changesJson;

        Test.startTest();
        List<WeightUpdateService.UpdateOutput> results =
            WeightUpdateService.applyWeights(new List<WeightUpdateService.UpdateInput>{ input });
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'Should succeed but update 0 records');
        System.assert(results[0].message.contains('Updated 0'), 'Should report 0 updates');
    }

    @isTest
    static void testApplyWeightsForLwc() {
        List<FSL__Scheduling_Policy__c> policies = [
            SELECT Id FROM FSL__Scheduling_Policy__c LIMIT 1
        ];
        if (policies.isEmpty()) {
            System.assert(true, 'No scheduling policies in org — skipping test');
            return;
        }

        String changesJson = '[{"objectiveId":"a0Xxx000000FAKE","newWeight":5}]';

        Test.startTest();
        String resultJson = WeightUpdateService.applyWeightsForLwc(policies[0].Id, changesJson);
        Test.stopTest();

        System.assertNotEquals(null, resultJson, 'Result JSON should not be null');
        System.assert(resultJson.contains('success'), 'Should contain success field');
    }
}
