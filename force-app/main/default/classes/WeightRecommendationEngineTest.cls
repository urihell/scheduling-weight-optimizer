@isTest
private class WeightRecommendationEngineTest {

    @isTest
    static void testParseValidResponse() {
        OptimizationAnalysisService.AnalysisResult analysis = new OptimizationAnalysisService.AnalysisResult();
        analysis.policyName = 'Test Policy';
        analysis.totalRunsAnalyzed = 5;
        analysis.currentWeights = new List<OptimizationAnalysisService.ObjectiveWeight>{
            new OptimizationAnalysisService.ObjectiveWeight('obj1', 'Minimize Travel', 'Objective_Minimize_Travel', 5)
        };

        String llmJson = '{'
            + '"recommendations": [{'
            + '  "objectiveId": "obj1",'
            + '  "objectiveName": "Minimize Travel",'
            + '  "objectiveType": "Objective_Minimize_Travel",'
            + '  "currentWeight": 5,'
            + '  "recommendedWeight": 8,'
            + '  "reasoning": "Travel efficiency is averaging -2.3% across runs"'
            + '}],'
            + '"summary": "Travel metrics are underperforming.",'
            + '"confidence": "high"'
            + '}';

        Test.startTest();
        WeightRecommendationEngine.RecommendationResult result =
            WeightRecommendationEngine.parseResponse(llmJson, analysis);
        Test.stopTest();

        System.assertEquals(1, result.recommendations.size(), 'Should have 1 recommendation');
        System.assertEquals('obj1', result.recommendations[0].objectiveId);
        System.assertEquals(5, result.recommendations[0].currentWeight);
        System.assertEquals(8, result.recommendations[0].recommendedWeight);
        System.assertEquals('high', result.confidence);
        System.assertNotEquals(null, result.summary);
    }

    @isTest
    static void testParseResponseWithCodeFences() {
        OptimizationAnalysisService.AnalysisResult analysis = new OptimizationAnalysisService.AnalysisResult();
        analysis.policyName = 'Test';
        analysis.totalRunsAnalyzed = 1;
        analysis.currentWeights = new List<OptimizationAnalysisService.ObjectiveWeight>();

        String llmJson = '```json\n{"recommendations": [], "summary": "All good.", "confidence": "high"}\n```';

        Test.startTest();
        WeightRecommendationEngine.RecommendationResult result =
            WeightRecommendationEngine.parseResponse(llmJson, analysis);
        Test.stopTest();

        System.assertEquals(0, result.recommendations.size());
        System.assertEquals('All good.', result.summary);
        System.assertEquals('high', result.confidence);
    }

    @isTest
    static void testParseMalformedResponse() {
        OptimizationAnalysisService.AnalysisResult analysis = new OptimizationAnalysisService.AnalysisResult();
        analysis.policyName = 'Test';
        analysis.totalRunsAnalyzed = 1;
        analysis.currentWeights = new List<OptimizationAnalysisService.ObjectiveWeight>();

        String badResponse = 'This is not valid JSON at all.';

        Test.startTest();
        WeightRecommendationEngine.RecommendationResult result =
            WeightRecommendationEngine.parseResponse(badResponse, analysis);
        Test.stopTest();

        System.assertEquals('low', result.confidence);
        System.assert(result.summary.contains('not valid JSON'), 'Summary should contain raw response');
    }

    @isTest
    static void testBuildSystemPrompt() {
        Test.startTest();
        String prompt = WeightRecommendationEngine.buildSystemPrompt();
        Test.stopTest();

        System.assert(prompt.contains('Salesforce Field Service'), 'Should mention FSL');
        System.assert(prompt.contains('Objective_Minimize_Travel'), 'Should list objective types');
        System.assert(prompt.contains('1-10'), 'Should mention weight scale');
        System.assert(prompt.contains('JSON'), 'Should request JSON format');
    }

    @isTest
    static void testInvocableWithInvalidName() {
        WeightRecommendationEngine.RecommendationInput input = new WeightRecommendationEngine.RecommendationInput();
        input.schedulingPolicyIdentifier = 'NonExistent_Policy_XYZ_99999';

        Test.startTest();
        List<WeightRecommendationEngine.RecommendationOutput> outputs =
            WeightRecommendationEngine.getRecommendations(
                new List<WeightRecommendationEngine.RecommendationInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        System.assertEquals(false, outputs[0].success);
    }
}
