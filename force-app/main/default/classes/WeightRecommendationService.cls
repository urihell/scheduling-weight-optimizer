public with sharing class WeightRecommendationService {

    @InvocableMethod(label='Analyze Scheduling Policy Performance'
                     description='Analyzes historical optimization data for a scheduling policy and returns structured performance metrics as JSON')
    public static List<AnalysisOutput> analyzePerformance(List<AnalysisInput> inputs) {
        List<AnalysisOutput> outputs = new List<AnalysisOutput>();

        for (AnalysisInput input : inputs) {
            AnalysisOutput output = new AnalysisOutput();
            try {
                String policyId = input.schedulingPolicyId;
                if (String.isBlank(policyId) && String.isNotBlank(input.schedulingPolicyName)) {
                    List<FSL__Scheduling_Policy__c> policies = [
                        SELECT Id FROM FSL__Scheduling_Policy__c
                        WHERE Name = :input.schedulingPolicyName
                        LIMIT 1
                    ];
                    if (!policies.isEmpty()) {
                        policyId = policies[0].Id;
                    }
                }

                if (String.isBlank(policyId)) {
                    output.analysisJson = '{"error": "No scheduling policy found"}';
                    output.success = false;
                    outputs.add(output);
                    continue;
                }

                OptimizationAnalysisService.AnalysisResult result =
                    OptimizationAnalysisService.analyzePolicy(policyId);

                output.analysisJson = JSON.serialize(result);
                output.policyName = result.policyName;
                output.totalRuns = result.totalRunsAnalyzed;
                output.success = true;

            } catch (Exception e) {
                output.analysisJson = '{"error": "' + e.getMessage().escapeJava() + '"}';
                output.success = false;
            }
            outputs.add(output);
        }

        return outputs;
    }

    public class AnalysisInput {
        @InvocableVariable(label='Scheduling Policy ID' description='ID of the scheduling policy to analyze')
        public String schedulingPolicyId;

        @InvocableVariable(label='Scheduling Policy Name' description='Name of the scheduling policy to analyze (used if ID is not provided)')
        public String schedulingPolicyName;
    }

    public class AnalysisOutput {
        @InvocableVariable(label='Analysis JSON' description='Full analysis results as JSON')
        public String analysisJson;

        @InvocableVariable(label='Policy Name' description='Name of the analyzed scheduling policy')
        public String policyName;

        @InvocableVariable(label='Total Runs' description='Number of optimization runs analyzed')
        public Integer totalRuns;

        @InvocableVariable(label='Success' description='Whether the analysis completed successfully')
        public Boolean success;
    }

    // AuraEnabled wrapper for LWC (LWC cannot call @InvocableMethod directly)
    @AuraEnabled
    public static String analyzeForLwc(String schedulingPolicyId) {
        AnalysisInput input = new AnalysisInput();
        input.schedulingPolicyId = schedulingPolicyId;
        List<AnalysisOutput> results = analyzePerformance(new List<AnalysisInput>{ input });
        return JSON.serialize(results[0]);
    }
}
