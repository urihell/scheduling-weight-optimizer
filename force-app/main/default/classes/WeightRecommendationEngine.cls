public with sharing class WeightRecommendationEngine {

    // ── Wrapper Classes ──

    public class RecommendationResult {
        @AuraEnabled public List<WeightRecommendation> recommendations;
        @AuraEnabled public String summary;
        @AuraEnabled public String confidence;
        @AuraEnabled public Integer runsAnalyzed;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String error;
    }

    public class WeightRecommendation {
        @AuraEnabled public String objectiveId;
        @AuraEnabled public String objectiveName;
        @AuraEnabled public String objectiveType;
        @AuraEnabled public Decimal currentWeight;
        @AuraEnabled public Decimal recommendedWeight;
        @AuraEnabled public String reasoning;
    }

    // ── Invocable for Agentforce ──

    @InvocableMethod(label='Get AI Weight Recommendations'
                     description='Analyzes historical optimization data using AI to recommend optimal weight changes grounded in actual performance patterns')
    public static List<RecommendationOutput> getRecommendations(List<RecommendationInput> inputs) {
        List<RecommendationOutput> outputs = new List<RecommendationOutput>();
        for (RecommendationInput input : inputs) {
            RecommendationOutput output = new RecommendationOutput();
            try {
                String policyId = resolvePolicyId(input.schedulingPolicyIdentifier);
                if (String.isBlank(policyId)) {
                    output.recommendationJson = '{"error": "No scheduling policy found"}';
                    output.success = false;
                    outputs.add(output);
                    continue;
                }
                RecommendationResult result = generateRecommendations(policyId);
                output.recommendationJson = JSON.serialize(result);
                output.summary = result.summary;
                output.confidence = result.confidence;
                output.success = result.success;
            } catch (Exception e) {
                output.recommendationJson = '{"error": "' + e.getMessage().escapeJava() + '"}';
                output.success = false;
            }
            outputs.add(output);
        }
        return outputs;
    }

    public class RecommendationInput {
        @InvocableVariable(required=true label='Scheduling Policy ID or Name')
        public String schedulingPolicyIdentifier;
    }

    public class RecommendationOutput {
        @InvocableVariable(label='Recommendation JSON')
        public String recommendationJson;
        @InvocableVariable(label='Summary')
        public String summary;
        @InvocableVariable(label='Confidence')
        public String confidence;
        @InvocableVariable(label='Success')
        public Boolean success;
    }

    // ── AuraEnabled for LWC ──

    @AuraEnabled
    public static String getRecommendationsForLwc(String schedulingPolicyId) {
        RecommendationResult result = generateRecommendations(schedulingPolicyId);
        return JSON.serialize(result);
    }

    // ── Core: Generate Recommendations via LLM ──

    public static RecommendationResult generateRecommendations(String schedulingPolicyId) {
        // Step 1: Get historical analysis data
        OptimizationAnalysisService.AnalysisResult analysis =
            OptimizationAnalysisService.analyzePolicy(schedulingPolicyId);

        if (analysis.runs == null || analysis.runs.isEmpty()) {
            RecommendationResult empty = new RecommendationResult();
            empty.success = false;
            empty.error = 'No completed optimization runs found for this policy. Run at least one optimization before requesting recommendations.';
            empty.recommendations = new List<WeightRecommendation>();
            empty.confidence = 'none';
            empty.runsAnalyzed = 0;
            return empty;
        }

        // Step 2: Build the prompt with analysis data
        String analysisJson = JSON.serialize(analysis);
        String systemPrompt = buildSystemPrompt();
        String userPrompt = 'Here is the historical optimization data for the scheduling policy "' +
            analysis.policyName + '":\n\n' + analysisJson +
            '\n\nAnalyze this data and provide your weight recommendations as JSON.';

        // Step 3: Call LLM via ConnectApi
        String llmResponse = callLlm(systemPrompt, userPrompt);

        // Step 4: Parse LLM response into structured result
        RecommendationResult result = parseResponse(llmResponse, analysis);
        result.runsAnalyzed = analysis.totalRunsAnalyzed;
        result.success = true;
        return result;
    }

    // ── Build System Prompt ──

    @TestVisible
    private static String buildSystemPrompt() {
        return 'You are a Salesforce Field Service scheduling optimization expert. '
            + 'You will receive historical optimization run data including current objective weights, '
            + 'per-run before/after metrics, and aggregate performance.\n\n'
            + 'Analyze the data to identify:\n'
            + '- Which metrics are underperforming (low or negative deltas)\n'
            + '- Which objectives may be over-weighted (high weight but poor related metrics)\n'
            + '- Which objectives may be under-weighted (low weight with room for improvement)\n'
            + '- Trends across runs (improving, declining, or stable)\n\n'
            + 'Ground every recommendation in specific data points from the analysis. '
            + 'Do not use hardcoded formulas. Reason from the actual metric patterns.\n\n'
            + 'Objective types and their primary impact:\n'
            + '- Objective_Asap: schedule rate (getting appointments scheduled quickly)\n'
            + '- Objective_Minimize_Travel: travel time reduction\n'
            + '- Objective_Minimize_Overtime: overtime reduction\n'
            + '- Objective_Minimize_Gaps: utilization (filling gaps in schedules)\n'
            + '- Objective_PreferredEngineer: preferred resource matching\n'
            + '- Objective_Resource_Priority: resource priority matching\n'
            + '- Objective_Skill_Level: skill-based assignment quality\n'
            + '- Objective_Skill_Preferences: skill preference matching\n'
            + '- Objective_Same_Site: grouping work at same location\n\n'
            + 'Weight scale is 1-10. Only recommend changes where the data supports it.\n\n'
            + 'Respond ONLY with a JSON object in this exact format (no markdown, no code fences):\n'
            + '{\n'
            + '  "recommendations": [\n'
            + '    {\n'
            + '      "objectiveId": "the FSL__Service_Goal__c ID",\n'
            + '      "objectiveName": "objective name",\n'
            + '      "objectiveType": "objective type",\n'
            + '      "currentWeight": 5,\n'
            + '      "recommendedWeight": 7,\n'
            + '      "reasoning": "specific data-driven reason for this change"\n'
            + '    }\n'
            + '  ],\n'
            + '  "summary": "2-3 sentence overall analysis summary",\n'
            + '  "confidence": "high|medium|low"\n'
            + '}';
    }

    // ── Call LLM via ConnectApi ──

    @TestVisible
    private static String callLlm(String systemPrompt, String userPrompt) {
        ConnectApi.EinsteinLlmGenerationsInput genInput = new ConnectApi.EinsteinLlmGenerationsInput();

        // Combine system prompt and user prompt into a single prompt string
        genInput.promptTextorId = systemPrompt + '\n\n' + userPrompt;
        genInput.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        genInput.additionalConfig.maxTokens = 2000;
        genInput.additionalConfig.applicationName = 'SchedulingWeightOptimizer';

        ConnectApi.EinsteinLLMGenerationsOutput genOutput =
            ConnectApi.EinsteinLlm.generateMessages(genInput);

        if (genOutput.generations == null || genOutput.generations.isEmpty()) {
            throw new AuraHandledException('LLM returned no response');
        }

        return genOutput.generations[0].text;
    }

    // ── Parse LLM Response ──

    @TestVisible
    private static RecommendationResult parseResponse(
        String llmResponse,
        OptimizationAnalysisService.AnalysisResult analysis
    ) {
        RecommendationResult result = new RecommendationResult();
        result.recommendations = new List<WeightRecommendation>();

        try {
            // Strip markdown code fences if present
            String cleaned = llmResponse.trim();
            if (cleaned.startsWith('```')) {
                cleaned = cleaned.substringAfter('\n');
                if (cleaned.endsWith('```')) {
                    cleaned = cleaned.substringBeforeLast('```');
                }
                cleaned = cleaned.trim();
            }

            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(cleaned);

            result.summary = (String) parsed.get('summary');
            result.confidence = (String) parsed.get('confidence');

            List<Object> recs = (List<Object>) parsed.get('recommendations');
            if (recs != null) {
                for (Object recObj : recs) {
                    Map<String, Object> rec = (Map<String, Object>) recObj;
                    WeightRecommendation wr = new WeightRecommendation();
                    wr.objectiveId = (String) rec.get('objectiveId');
                    wr.objectiveName = (String) rec.get('objectiveName');
                    wr.objectiveType = (String) rec.get('objectiveType');
                    wr.currentWeight = toDecimal(rec.get('currentWeight'));
                    wr.recommendedWeight = toDecimal(rec.get('recommendedWeight'));
                    wr.reasoning = (String) rec.get('reasoning');
                    result.recommendations.add(wr);
                }
            }
        } catch (Exception e) {
            // If parsing fails, return the raw response as summary
            result.summary = llmResponse;
            result.confidence = 'low';
        }

        return result;
    }

    // ── Helpers ──

    private static String resolvePolicyId(String identifier) {
        if (String.isBlank(identifier)) return null;
        if (identifier instanceof Id) return identifier;
        List<FSL__Scheduling_Policy__c> policies = [
            SELECT Id FROM FSL__Scheduling_Policy__c
            WHERE Name = :identifier LIMIT 1
        ];
        return policies.isEmpty() ? null : policies[0].Id;
    }

    private static Decimal toDecimal(Object val) {
        if (val == null) return 0;
        if (val instanceof Decimal) return (Decimal) val;
        if (val instanceof Integer) return (Decimal) ((Integer) val);
        return Decimal.valueOf(String.valueOf(val));
    }
}
