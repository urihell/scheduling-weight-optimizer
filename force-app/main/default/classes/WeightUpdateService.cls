public with sharing class WeightUpdateService {

    @InvocableMethod(label='Apply Weight Recommendations'
                     description='Updates scheduling objective weights on a scheduling policy')
    public static List<UpdateOutput> applyWeights(List<UpdateInput> inputs) {
        List<UpdateOutput> outputs = new List<UpdateOutput>();

        for (UpdateInput input : inputs) {
            UpdateOutput output = new UpdateOutput();
            try {
                List<WeightChange> changes = (List<WeightChange>)
                    JSON.deserialize(input.weightChangesJson, List<WeightChange>.class);

                List<FSL__Scheduling_Policy_Goal__c> policyGoals = [
                    SELECT Id, FSL__Service_Goal__c, FSL__Weight__c,
                           FSL__Service_Goal__r.Name
                    FROM FSL__Scheduling_Policy_Goal__c
                    WHERE FSL__Scheduling_Policy__c = :input.schedulingPolicyId
                ];

                Map<String, FSL__Scheduling_Policy_Goal__c> goalMap = new Map<String, FSL__Scheduling_Policy_Goal__c>();
                for (FSL__Scheduling_Policy_Goal__c pg : policyGoals) {
                    goalMap.put(pg.FSL__Service_Goal__c, pg);
                }

                List<FSL__Scheduling_Policy_Goal__c> toUpdate = new List<FSL__Scheduling_Policy_Goal__c>();
                List<String> changeLog = new List<String>();

                for (WeightChange wc : changes) {
                    FSL__Scheduling_Policy_Goal__c pg = goalMap.get(wc.objectiveId);
                    if (pg != null) {
                        Decimal oldWeight = pg.FSL__Weight__c;
                        pg.FSL__Weight__c = wc.newWeight;
                        toUpdate.add(pg);
                        changeLog.add(pg.FSL__Service_Goal__r.Name + ': ' + oldWeight + ' → ' + wc.newWeight);
                    }
                }

                if (!toUpdate.isEmpty()) {
                    update toUpdate;
                }

                output.success = true;
                output.message = 'Updated ' + toUpdate.size() + ' objective weights: ' + String.join(changeLog, '; ');

            } catch (Exception e) {
                output.success = false;
                output.message = 'Error applying weights: ' + e.getMessage();
            }
            outputs.add(output);
        }

        return outputs;
    }

    public class UpdateInput {
        @InvocableVariable(required=true label='Scheduling Policy ID' description='ID of the scheduling policy to update')
        public String schedulingPolicyId;

        @InvocableVariable(required=true label='Weight Changes JSON' description='JSON array of {objectiveId, newWeight} objects')
        public String weightChangesJson;
    }

    public class UpdateOutput {
        @InvocableVariable(label='Success' description='Whether the update completed successfully')
        public Boolean success;

        @InvocableVariable(label='Message' description='Description of changes made or error message')
        public String message;
    }

    public class WeightChange {
        public String objectiveId;
        public Decimal newWeight;
    }

    // AuraEnabled wrapper for LWC (LWC cannot call @InvocableMethod directly)
    @AuraEnabled
    public static String applyWeightsForLwc(String schedulingPolicyId, String weightChangesJson) {
        UpdateInput input = new UpdateInput();
        input.schedulingPolicyId = schedulingPolicyId;
        input.weightChangesJson = weightChangesJson;
        List<UpdateOutput> results = applyWeights(new List<UpdateInput>{ input });
        return JSON.serialize(results[0]);
    }
}
