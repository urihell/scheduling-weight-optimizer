@isTest
private class WeightRecommendationEngineTest {

    // ── Helper: build a RunMetrics with specified values ──

    private static OptimizationAnalysisService.RunMetrics buildRun(
        Decimal scheduleRate, Decimal travel, Decimal overtime,
        Decimal utilization, Decimal preferred
    ) {
        OptimizationAnalysisService.RunMetrics rm = new OptimizationAnalysisService.RunMetrics();
        rm.scheduleRateDelta = scheduleRate;
        rm.travelEfficiency = travel;
        rm.overtimeReduction = overtime;
        rm.utilizationDelta = utilization;
        rm.preferredResourceRate = preferred;
        rm.optimizationRequestName = 'Run';
        return rm;
    }

    // ── Helper: build an AnalysisResult with weights and runs ──

    private static OptimizationAnalysisService.AnalysisResult buildAnalysis(
        List<OptimizationAnalysisService.ObjectiveWeight> weights,
        List<OptimizationAnalysisService.RunMetrics> runs
    ) {
        OptimizationAnalysisService.AnalysisResult analysis = new OptimizationAnalysisService.AnalysisResult();
        analysis.policyName = 'Test Policy';
        analysis.currentWeights = weights;
        analysis.runs = runs;
        analysis.totalRunsAnalyzed = runs.size();
        analysis.aggregates = new OptimizationAnalysisService.AggregateMetrics();
        analysis.aggregates.trend = 'stable';
        return analysis;
    }

    // ── Parse Response Tests ──

    @isTest
    static void testParseValidResponse() {
        OptimizationAnalysisService.AnalysisResult analysis = buildAnalysis(
            new List<OptimizationAnalysisService.ObjectiveWeight>{
                new OptimizationAnalysisService.ObjectiveWeight('obj1', 'Minimize Travel', 'Objective_Minimize_Travel', 5)
            },
            new List<OptimizationAnalysisService.RunMetrics>{ buildRun(5, 12, 8, 3, 40) }
        );

        String llmJson = '{'
            + '"recommendations": [{'
            + '  "objectiveId": "obj1",'
            + '  "objectiveName": "Minimize Travel",'
            + '  "objectiveType": "Objective_Minimize_Travel",'
            + '  "currentWeight": 5,'
            + '  "recommendedWeight": 8,'
            + '  "reasoning": "Travel efficiency is strong at 12% avg"'
            + '}],'
            + '"summary": "Travel metrics are performing well.",'
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
        OptimizationAnalysisService.AnalysisResult analysis = buildAnalysis(
            new List<OptimizationAnalysisService.ObjectiveWeight>(),
            new List<OptimizationAnalysisService.RunMetrics>{ buildRun(5, 12, 8, 3, 40) }
        );

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
        OptimizationAnalysisService.AnalysisResult analysis = buildAnalysis(
            new List<OptimizationAnalysisService.ObjectiveWeight>(),
            new List<OptimizationAnalysisService.RunMetrics>{ buildRun(5, 12, 8, 3, 40) }
        );

        String badResponse = 'This is not valid JSON at all.';

        Test.startTest();
        WeightRecommendationEngine.RecommendationResult result =
            WeightRecommendationEngine.parseResponse(badResponse, analysis);
        Test.stopTest();

        System.assertEquals('low', result.confidence);
        System.assert(result.summary.contains('not valid JSON'), 'Summary should contain raw response');
    }

    // ── System Prompt Tests ──

    @isTest
    static void testBuildSystemPrompt() {
        Test.startTest();
        String prompt = WeightRecommendationEngine.buildSystemPrompt();
        Test.stopTest();

        System.assert(prompt.contains('PRE-COMPUTED analysis digest'), 'Should reference digest approach');
        System.assert(prompt.contains('Do NOT recalculate'), 'Should instruct not to recalculate');
        System.assert(prompt.contains('1-10'), 'Should mention weight scale');
        System.assert(prompt.contains('JSON'), 'Should request JSON format');
        System.assert(prompt.contains('tradeoffs'), 'Should mention objective tradeoffs');
    }

    // ── Invocable Tests ──

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

    // ── Digest Computation Tests ──

    @isTest
    static void testComputeDigestMetricRatings() {
        List<OptimizationAnalysisService.ObjectiveWeight> weights = new List<OptimizationAnalysisService.ObjectiveWeight>{
            new OptimizationAnalysisService.ObjectiveWeight('obj1', 'ASAP', 'Objective_Asap', 7),
            new OptimizationAnalysisService.ObjectiveWeight('obj2', 'Travel', 'Objective_Minimize_Travel', 3),
            new OptimizationAnalysisService.ObjectiveWeight('obj3', 'Skills', 'Objective_Skill_Level', 5)
        };

        // 4 runs to enable trend detection
        List<OptimizationAnalysisService.RunMetrics> runs = new List<OptimizationAnalysisService.RunMetrics>{
            buildRun(1.5, 15, -2, 0.5, 45),
            buildRun(1.0, 12, -1, 0.8, 42),
            buildRun(2.0, 18, 3, 1.2, 50),
            buildRun(1.8, 20, 5, 1.5, 48)
        };

        OptimizationAnalysisService.AnalysisResult analysis = buildAnalysis(weights, runs);

        Test.startTest();
        // Access via JSON round-trip since PolicyDigest is private
        Object digestObj = WeightRecommendationEngine.computeDigest(analysis);
        String digestJson = JSON.serialize(digestObj);
        Map<String, Object> digest = (Map<String, Object>) JSON.deserializeUntyped(digestJson);
        Test.stopTest();

        // Verify structure
        System.assertEquals('Test Policy', digest.get('policyName'));
        System.assertEquals(4, digest.get('runsAnalyzed'));

        // Verify metrics exist
        List<Object> metrics = (List<Object>) digest.get('metrics');
        System.assertEquals(5, metrics.size(), 'Should have 5 metric digests');

        // Find the Schedule Rate metric (avg ~1.575 — should be 'weak')
        Map<String, Object> schedRate = null;
        Map<String, Object> travelMetric = null;
        for (Object m : metrics) {
            Map<String, Object> metric = (Map<String, Object>) m;
            if (metric.get('metricName') == 'Schedule Rate') schedRate = metric;
            if (metric.get('metricName') == 'Travel Reduction') travelMetric = metric;
        }
        System.assertNotEquals(null, schedRate, 'Schedule Rate metric should exist');
        System.assertEquals('weak', schedRate.get('performanceRating'), 'Avg ~1.6% should be weak');
        System.assertEquals('Objective_Asap', schedRate.get('linkedObjectiveType'));

        // Travel avg ~16.25 — should be 'strong'
        System.assertNotEquals(null, travelMetric);
        System.assertEquals('strong', travelMetric.get('performanceRating'), 'Avg ~16.25% should be strong');

        // Verify objectives
        List<Object> objectives = (List<Object>) digest.get('objectives');
        System.assertEquals(3, objectives.size(), 'Should have 3 objective digests');

        // Skills objective should have insufficient_data
        Map<String, Object> skillsObj = null;
        Map<String, Object> asapObj = null;
        Map<String, Object> travelObj = null;
        for (Object o : objectives) {
            Map<String, Object> obj = (Map<String, Object>) o;
            if (obj.get('objectiveType') == 'Objective_Skill_Level') skillsObj = obj;
            if (obj.get('objectiveType') == 'Objective_Asap') asapObj = obj;
            if (obj.get('objectiveType') == 'Objective_Minimize_Travel') travelObj = obj;
        }
        System.assertEquals('insufficient_data', skillsObj.get('suggestedDirection'));
        System.assertEquals(false, skillsObj.get('hasMeasurableData'));

        // ASAP: weak metric + weight 7 → decrease
        System.assertEquals('decrease', asapObj.get('suggestedDirection'));
        System.assertEquals(true, asapObj.get('hasMeasurableData'));

        // Travel: strong metric + weight 3 → increase
        System.assertEquals('increase', travelObj.get('suggestedDirection'));

        // Verify key findings exist
        List<Object> findings = (List<Object>) digest.get('keyFindings');
        System.assert(!findings.isEmpty(), 'Should have key findings');

        // Verify confidence is computed
        // 4 runs (20pts) + 2/3 measurable ~67% (35pts) + low variance (25pts) = 80 → high
        System.assertNotEquals(null, digest.get('confidence'), 'Confidence should be computed');
    }

    @isTest
    static void testComputeDigestNoRuns() {
        OptimizationAnalysisService.AnalysisResult analysis = buildAnalysis(
            new List<OptimizationAnalysisService.ObjectiveWeight>{
                new OptimizationAnalysisService.ObjectiveWeight('obj1', 'ASAP', 'Objective_Asap', 5)
            },
            new List<OptimizationAnalysisService.RunMetrics>()
        );

        Test.startTest();
        Object digestObj = WeightRecommendationEngine.computeDigest(analysis);
        String digestJson = JSON.serialize(digestObj);
        Map<String, Object> digest = (Map<String, Object>) JSON.deserializeUntyped(digestJson);
        Test.stopTest();

        List<Object> metrics = (List<Object>) digest.get('metrics');
        System.assertEquals(5, metrics.size(), 'Should still have 5 metrics');
        for (Object m : metrics) {
            Map<String, Object> metric = (Map<String, Object>) m;
            System.assertEquals('negative', metric.get('performanceRating'));
            System.assertEquals('stable', metric.get('trend'));
        }
    }

    // ── Trend Computation Tests ──

    @isTest
    static void testComputeTrendImproving() {
        List<Decimal> values = new List<Decimal>{ 1, 2, 5, 8 };
        System.assertEquals('improving', WeightRecommendationEngine.computeTrend(values));
    }

    @isTest
    static void testComputeTrendDeclining() {
        List<Decimal> values = new List<Decimal>{ 10, 8, 3, 1 };
        System.assertEquals('declining', WeightRecommendationEngine.computeTrend(values));
    }

    @isTest
    static void testComputeTrendStable() {
        List<Decimal> values = new List<Decimal>{ 5, 5, 5, 5 };
        System.assertEquals('stable', WeightRecommendationEngine.computeTrend(values));
    }

    @isTest
    static void testComputeTrendTooFewRuns() {
        List<Decimal> values = new List<Decimal>{ 1, 10, 20 };
        System.assertEquals('stable', WeightRecommendationEngine.computeTrend(values),
            'Should default to stable with < 4 data points');
    }

    // ── Standard Deviation Test ──

    @isTest
    static void testComputeStdDev() {
        List<Decimal> values = new List<Decimal>{ 2, 4, 4, 4, 5, 5, 7, 9 };
        Decimal mean = 5;
        Decimal stdDev = WeightRecommendationEngine.computeStdDev(values, mean);
        // Expected: sqrt(((9+1+1+1+0+0+4+16)/8)) = sqrt(4) = 2
        System.assertEquals(2.0, stdDev.setScale(1), 'Std dev of [2,4,4,4,5,5,7,9] with mean 5 should be 2');
    }

    @isTest
    static void testComputeStdDevSingleValue() {
        List<Decimal> values = new List<Decimal>{ 5 };
        System.assertEquals(0, WeightRecommendationEngine.computeStdDev(values, 5),
            'Single value should have 0 std dev');
    }

    // ── Validate Response Tests ──

    @isTest
    static void testValidateResponseClampsWeights() {
        OptimizationAnalysisService.AnalysisResult analysis = buildAnalysis(
            new List<OptimizationAnalysisService.ObjectiveWeight>{
                new OptimizationAnalysisService.ObjectiveWeight('obj1', 'ASAP', 'Objective_Asap', 5),
                new OptimizationAnalysisService.ObjectiveWeight('obj2', 'Travel', 'Objective_Minimize_Travel', 3)
            },
            new List<OptimizationAnalysisService.RunMetrics>{ buildRun(5, 12, 8, 3, 40) }
        );

        WeightRecommendationEngine.RecommendationResult result = new WeightRecommendationEngine.RecommendationResult();
        result.recommendations = new List<WeightRecommendationEngine.WeightRecommendation>();
        result.confidence = 'high';

        // Weight too high
        WeightRecommendationEngine.WeightRecommendation wr1 = new WeightRecommendationEngine.WeightRecommendation();
        wr1.objectiveId = 'obj1';
        wr1.objectiveName = 'ASAP';
        wr1.objectiveType = 'Objective_Asap';
        wr1.currentWeight = 5;
        wr1.recommendedWeight = 15; // Out of range
        wr1.reasoning = 'Test';
        result.recommendations.add(wr1);

        // Weight too low
        WeightRecommendationEngine.WeightRecommendation wr2 = new WeightRecommendationEngine.WeightRecommendation();
        wr2.objectiveId = 'obj2';
        wr2.objectiveName = 'Travel';
        wr2.objectiveType = 'Objective_Minimize_Travel';
        wr2.currentWeight = 3;
        wr2.recommendedWeight = -2; // Out of range
        wr2.reasoning = 'Test';
        result.recommendations.add(wr2);

        Test.startTest();
        WeightRecommendationEngine.RecommendationResult validated =
            WeightRecommendationEngine.validateResponse(result, analysis);
        Test.stopTest();

        System.assertEquals(2, validated.recommendations.size());
        // Find each by objectiveId
        for (WeightRecommendationEngine.WeightRecommendation wr : validated.recommendations) {
            if (wr.objectiveId == 'obj1') {
                System.assertEquals(10, wr.recommendedWeight, 'Should be clamped to 10');
            }
            if (wr.objectiveId == 'obj2') {
                System.assertEquals(1, wr.recommendedWeight, 'Should be clamped to 1');
            }
        }
    }

    @isTest
    static void testValidateResponseFillsMissing() {
        OptimizationAnalysisService.AnalysisResult analysis = buildAnalysis(
            new List<OptimizationAnalysisService.ObjectiveWeight>{
                new OptimizationAnalysisService.ObjectiveWeight('obj1', 'ASAP', 'Objective_Asap', 5),
                new OptimizationAnalysisService.ObjectiveWeight('obj2', 'Travel', 'Objective_Minimize_Travel', 3),
                new OptimizationAnalysisService.ObjectiveWeight('obj3', 'Overtime', 'Objective_Minimize_Overtime', 7)
            },
            new List<OptimizationAnalysisService.RunMetrics>{ buildRun(5, 12, 8, 3, 40) }
        );

        // LLM only returned 1 of 3 objectives
        WeightRecommendationEngine.RecommendationResult result = new WeightRecommendationEngine.RecommendationResult();
        result.recommendations = new List<WeightRecommendationEngine.WeightRecommendation>();
        result.confidence = 'medium';

        WeightRecommendationEngine.WeightRecommendation wr1 = new WeightRecommendationEngine.WeightRecommendation();
        wr1.objectiveId = 'obj1';
        wr1.objectiveName = 'ASAP';
        wr1.objectiveType = 'Objective_Asap';
        wr1.currentWeight = 5;
        wr1.recommendedWeight = 7;
        wr1.reasoning = 'Increase ASAP';
        result.recommendations.add(wr1);

        Test.startTest();
        WeightRecommendationEngine.RecommendationResult validated =
            WeightRecommendationEngine.validateResponse(result, analysis);
        Test.stopTest();

        System.assertEquals(3, validated.recommendations.size(), 'Should have all 3 objectives');

        // Check that missing objectives got filled with current weight
        Set<String> ids = new Set<String>();
        for (WeightRecommendationEngine.WeightRecommendation wr : validated.recommendations) {
            ids.add(wr.objectiveId);
            if (wr.objectiveId == 'obj2') {
                System.assertEquals(3, wr.recommendedWeight, 'Missing objective should keep current weight');
                System.assert(wr.reasoning.contains('No change'), 'Should have default reasoning');
            }
            if (wr.objectiveId == 'obj3') {
                System.assertEquals(7, wr.recommendedWeight, 'Missing objective should keep current weight');
            }
        }
        System.assert(ids.contains('obj1') && ids.contains('obj2') && ids.contains('obj3'));
    }

    @isTest
    static void testValidateResponseRemovesInvalidIds() {
        OptimizationAnalysisService.AnalysisResult analysis = buildAnalysis(
            new List<OptimizationAnalysisService.ObjectiveWeight>{
                new OptimizationAnalysisService.ObjectiveWeight('obj1', 'ASAP', 'Objective_Asap', 5)
            },
            new List<OptimizationAnalysisService.RunMetrics>{ buildRun(5, 12, 8, 3, 40) }
        );

        WeightRecommendationEngine.RecommendationResult result = new WeightRecommendationEngine.RecommendationResult();
        result.recommendations = new List<WeightRecommendationEngine.WeightRecommendation>();

        // Valid recommendation
        WeightRecommendationEngine.WeightRecommendation wr1 = new WeightRecommendationEngine.WeightRecommendation();
        wr1.objectiveId = 'obj1';
        wr1.objectiveName = 'ASAP';
        wr1.recommendedWeight = 7;
        wr1.reasoning = 'Valid';
        result.recommendations.add(wr1);

        // Hallucinated objective
        WeightRecommendationEngine.WeightRecommendation wr2 = new WeightRecommendationEngine.WeightRecommendation();
        wr2.objectiveId = 'hallucinated_id';
        wr2.objectiveName = 'Fake Objective';
        wr2.recommendedWeight = 9;
        wr2.reasoning = 'Hallucinated';
        result.recommendations.add(wr2);

        Test.startTest();
        WeightRecommendationEngine.RecommendationResult validated =
            WeightRecommendationEngine.validateResponse(result, analysis);
        Test.stopTest();

        System.assertEquals(1, validated.recommendations.size(), 'Hallucinated objective should be removed');
        System.assertEquals('obj1', validated.recommendations[0].objectiveId);
    }

    @isTest
    static void testValidateResponseDefaultsConfidence() {
        OptimizationAnalysisService.AnalysisResult analysis = buildAnalysis(
            new List<OptimizationAnalysisService.ObjectiveWeight>(),
            new List<OptimizationAnalysisService.RunMetrics>{ buildRun(5, 12, 8, 3, 40) }
        );

        WeightRecommendationEngine.RecommendationResult result = new WeightRecommendationEngine.RecommendationResult();
        result.recommendations = new List<WeightRecommendationEngine.WeightRecommendation>();
        result.confidence = null;

        Test.startTest();
        WeightRecommendationEngine.RecommendationResult validated =
            WeightRecommendationEngine.validateResponse(result, analysis);
        Test.stopTest();

        System.assertEquals('low', validated.confidence, 'Null confidence should default to low');
    }

    // ── Confidence Computation Tests ──

    @isTest
    static void testComputeConfidenceHigh() {
        // 20+ runs (40pts), 100% coverage (35pts), low variance (25pts) = 100 → high
        List<OptimizationAnalysisService.ObjectiveWeight> weights = new List<OptimizationAnalysisService.ObjectiveWeight>{
            new OptimizationAnalysisService.ObjectiveWeight('o1', 'ASAP', 'Objective_Asap', 5),
            new OptimizationAnalysisService.ObjectiveWeight('o2', 'Travel', 'Objective_Minimize_Travel', 5),
            new OptimizationAnalysisService.ObjectiveWeight('o3', 'Overtime', 'Objective_Minimize_Overtime', 5),
            new OptimizationAnalysisService.ObjectiveWeight('o4', 'Gaps', 'Objective_Minimize_Gaps', 5)
        };

        // 20 consistent runs
        List<OptimizationAnalysisService.RunMetrics> runs = new List<OptimizationAnalysisService.RunMetrics>();
        for (Integer i = 0; i < 20; i++) {
            runs.add(buildRun(5, 12, 8, 3, 40));
        }

        OptimizationAnalysisService.AnalysisResult analysis = buildAnalysis(weights, runs);

        Test.startTest();
        Object digestObj = WeightRecommendationEngine.computeDigest(analysis);
        Map<String, Object> digest = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(digestObj));
        Test.stopTest();

        System.assertEquals('high', digest.get('confidence'),
            '20+ runs, all measurable objectives, low variance should be high confidence');
    }

    @isTest
    static void testComputeConfidenceLow() {
        // 2 runs (10pts), 0% measurable coverage (5pts from 1 unmeasurable obj), high variance
        List<OptimizationAnalysisService.ObjectiveWeight> weights = new List<OptimizationAnalysisService.ObjectiveWeight>{
            new OptimizationAnalysisService.ObjectiveWeight('o1', 'Skills', 'Objective_Skill_Level', 5)
        };

        List<OptimizationAnalysisService.RunMetrics> runs = new List<OptimizationAnalysisService.RunMetrics>{
            buildRun(1, -5, -10, -2, 10),
            buildRun(20, 30, 25, 15, 80)
        };

        OptimizationAnalysisService.AnalysisResult analysis = buildAnalysis(weights, runs);

        Test.startTest();
        Object digestObj = WeightRecommendationEngine.computeDigest(analysis);
        Map<String, Object> digest = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(digestObj));
        Test.stopTest();

        System.assertEquals('low', digest.get('confidence'),
            'Few runs, no measurable objectives should be low confidence');
    }

    @isTest
    static void testComputeConfidenceMedium() {
        // 5 runs (20pts), 50% coverage 2/4 (25pts), high variance (5pts) = 50 → medium
        List<OptimizationAnalysisService.ObjectiveWeight> weights = new List<OptimizationAnalysisService.ObjectiveWeight>{
            new OptimizationAnalysisService.ObjectiveWeight('o1', 'ASAP', 'Objective_Asap', 6),
            new OptimizationAnalysisService.ObjectiveWeight('o2', 'Travel', 'Objective_Minimize_Travel', 5),
            new OptimizationAnalysisService.ObjectiveWeight('o3', 'Skills', 'Objective_Skill_Level', 5),
            new OptimizationAnalysisService.ObjectiveWeight('o4', 'Priority', 'Objective_Resource_Priority', 3)
        };

        // 5 runs with high variance to push consistency score down
        List<OptimizationAnalysisService.RunMetrics> runs = new List<OptimizationAnalysisService.RunMetrics>{
            buildRun(-10, -20, -15, -5, 10),
            buildRun(25, 35, 30, 15, 80),
            buildRun(-5, -10, -8, -2, 20),
            buildRun(20, 30, 25, 12, 70),
            buildRun(0, 5, 2, 1, 40)
        };

        OptimizationAnalysisService.AnalysisResult analysis = buildAnalysis(weights, runs);

        Test.startTest();
        Object digestObj = WeightRecommendationEngine.computeDigest(analysis);
        Map<String, Object> digest = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(digestObj));
        Test.stopTest();

        System.assertEquals('medium', digest.get('confidence'),
            '5 runs, 50% coverage, high variance should be medium confidence');
    }
}
