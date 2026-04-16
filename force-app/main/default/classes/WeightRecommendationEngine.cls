public with sharing class WeightRecommendationEngine {

    // ── Public Wrapper Classes (LWC contract — do not change) ──

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

    // ── Digest Classes (Apex-computed analysis for LLM) ──

    @TestVisible
    private class MetricDigest {
        public String metricName;
        public String linkedObjectiveType;
        public Decimal avgValue;
        public Decimal recentValue;
        public String trend;
        public Decimal variance;
        public String performanceRating;
    }

    @TestVisible
    private class ObjectiveDigest {
        public String objectiveId;
        public String objectiveName;
        public String objectiveType;
        public Decimal currentWeight;
        public Boolean hasMeasurableData;
        public String suggestedDirection;
        public String directionRationale;
    }

    @TestVisible
    private class PolicyDigest {
        public String policyName;
        public Integer runsAnalyzed;
        public String overallTrend;
        public String confidence;
        public List<MetricDigest> metrics;
        public List<ObjectiveDigest> objectives;
        public List<String> keyFindings;
    }

    // ── Metric-to-Objective mapping ──

    private static final Map<String, String> METRIC_TO_OBJECTIVE = new Map<String, String>{
        'Schedule Rate' => 'Objective_Asap',
        'Travel Reduction' => 'Objective_Minimize_Travel',
        'Overtime Reduction' => 'Objective_Minimize_Overtime',
        'Utilization' => 'Objective_Minimize_Gaps',
        'Preferred Resource' => 'Objective_PreferredEngineer'
    };

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

    // ── Core: Generate Recommendations (Hybrid Approach) ──

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

        // Step 2: Compute digest — Apex does the math
        PolicyDigest digest = computeDigest(analysis);

        // Step 3: Build prompt with digest (not raw data)
        String digestJson = JSON.serialize(digest);
        String systemPrompt = buildSystemPrompt();
        String userPrompt = 'Here is the pre-computed analysis digest for scheduling policy "'
            + analysis.policyName + '":\n\n' + digestJson
            + '\n\nRecommend specific weight values based on this analysis.';

        // Step 4: Call LLM
        String llmResponse = callLlm(systemPrompt, userPrompt);

        // Step 5: Parse LLM response
        RecommendationResult result = parseResponse(llmResponse, analysis);

        // Step 6: Validate and sanitize — use Apex-computed confidence
        result = validateResponse(result, analysis);
        result.confidence = digest.confidence;

        result.runsAnalyzed = analysis.totalRunsAnalyzed;
        result.success = true;
        return result;
    }

    // ── Compute Digest: Apex-driven numerical analysis ──

    @TestVisible
    private static PolicyDigest computeDigest(OptimizationAnalysisService.AnalysisResult analysis) {
        PolicyDigest digest = new PolicyDigest();
        digest.policyName = analysis.policyName;
        digest.runsAnalyzed = analysis.totalRunsAnalyzed;
        digest.overallTrend = analysis.aggregates != null ? analysis.aggregates.trend : 'stable';

        // Compute per-metric digests
        digest.metrics = new List<MetricDigest>();
        digest.metrics.add(buildMetricDigest('Schedule Rate', 'Objective_Asap', analysis.runs, 'scheduleRateDelta'));
        digest.metrics.add(buildMetricDigest('Travel Reduction', 'Objective_Minimize_Travel', analysis.runs, 'travelEfficiency'));
        digest.metrics.add(buildMetricDigest('Overtime Reduction', 'Objective_Minimize_Overtime', analysis.runs, 'overtimeReduction'));
        digest.metrics.add(buildMetricDigest('Utilization', 'Objective_Minimize_Gaps', analysis.runs, 'utilizationDelta'));
        digest.metrics.add(buildMetricDigest('Preferred Resource', 'Objective_PreferredEngineer', analysis.runs, 'preferredResourceRate'));

        // Build metric lookup for objective direction signals
        Map<String, MetricDigest> metricByObjective = new Map<String, MetricDigest>();
        for (MetricDigest md : digest.metrics) {
            metricByObjective.put(md.linkedObjectiveType, md);
        }

        // Compute per-objective digests
        digest.objectives = new List<ObjectiveDigest>();
        if (analysis.currentWeights != null) {
            for (OptimizationAnalysisService.ObjectiveWeight ow : analysis.currentWeights) {
                ObjectiveDigest od = new ObjectiveDigest();
                od.objectiveId = ow.objectiveId;
                od.objectiveName = ow.objectiveName;
                od.objectiveType = ow.objectiveType;
                od.currentWeight = ow.weight;

                MetricDigest linked = metricByObjective.get(ow.objectiveType);
                od.hasMeasurableData = (linked != null);

                if (linked == null) {
                    od.suggestedDirection = 'insufficient_data';
                    od.directionRationale = 'No measurable before/after metrics available for this objective type.';
                } else {
                    computeDirection(od, linked);
                }

                digest.objectives.add(od);
            }
        }

        // Generate key findings
        digest.keyFindings = generateKeyFindings(digest);

        // Compute deterministic confidence
        digest.confidence = computeConfidence(digest);

        return digest;
    }

    // ── Compute Confidence Deterministically ──

    @TestVisible
    private static String computeConfidence(PolicyDigest digest) {
        // Score: 0-100 across three dimensions, then map to high/medium/low

        // Dimension 1: Runs analyzed (0-40 points)
        Integer runsScore;
        if (digest.runsAnalyzed >= 20) {
            runsScore = 40;
        } else if (digest.runsAnalyzed >= 10) {
            runsScore = 30;
        } else if (digest.runsAnalyzed >= 4) {
            runsScore = 20;
        } else {
            runsScore = 10;
        }

        // Dimension 2: Data coverage — % of objectives with measurable data (0-35 points)
        Integer measurable = 0;
        Integer totalObjectives = digest.objectives != null ? digest.objectives.size() : 0;
        if (digest.objectives != null) {
            for (ObjectiveDigest od : digest.objectives) {
                if (od.hasMeasurableData) measurable++;
            }
        }
        Integer coverageScore;
        if (totalObjectives == 0) {
            coverageScore = 0;
        } else {
            Decimal coveragePct = (Decimal) measurable / totalObjectives * 100;
            if (coveragePct >= 75) {
                coverageScore = 35;
            } else if (coveragePct >= 50) {
                coverageScore = 25;
            } else if (coveragePct >= 25) {
                coverageScore = 15;
            } else {
                coverageScore = 5;
            }
        }

        // Dimension 3: Metric consistency — avg variance across metrics (0-25 points)
        Decimal totalVariance = 0;
        Integer metricCount = 0;
        if (digest.metrics != null) {
            for (MetricDigest md : digest.metrics) {
                if (md.variance != null) {
                    totalVariance += md.variance;
                    metricCount++;
                }
            }
        }
        Integer consistencyScore;
        if (metricCount == 0) {
            consistencyScore = 0;
        } else {
            Decimal avgVariance = totalVariance / metricCount;
            if (avgVariance < 5) {
                consistencyScore = 25;
            } else if (avgVariance < 10) {
                consistencyScore = 20;
            } else if (avgVariance < 20) {
                consistencyScore = 12;
            } else {
                consistencyScore = 5;
            }
        }

        Integer totalScore = runsScore + coverageScore + consistencyScore;

        if (totalScore >= 70) return 'high';
        if (totalScore >= 45) return 'medium';
        return 'low';
    }

    // ── Build a MetricDigest from per-run values ──

    private static MetricDigest buildMetricDigest(
        String metricName, String objectiveType,
        List<OptimizationAnalysisService.RunMetrics> runs, String fieldName
    ) {
        MetricDigest md = new MetricDigest();
        md.metricName = metricName;
        md.linkedObjectiveType = objectiveType;

        List<Decimal> values = new List<Decimal>();
        for (OptimizationAnalysisService.RunMetrics rm : runs) {
            values.add(getMetricValue(rm, fieldName));
        }

        if (values.isEmpty()) {
            md.avgValue = 0;
            md.recentValue = 0;
            md.trend = 'stable';
            md.variance = 0;
            md.performanceRating = 'negative';
            return md;
        }

        // Average
        Decimal sum = 0;
        for (Decimal v : values) {
            sum += v;
        }
        md.avgValue = sum / values.size();
        md.recentValue = values[values.size() - 1];

        // Trend (first-half vs second-half comparison)
        md.trend = computeTrend(values);

        // Standard deviation
        md.variance = computeStdDev(values, md.avgValue);

        // Performance rating
        if (md.avgValue > 10) {
            md.performanceRating = 'strong';
        } else if (md.avgValue > 2) {
            md.performanceRating = 'moderate';
        } else if (md.avgValue > 0) {
            md.performanceRating = 'weak';
        } else {
            md.performanceRating = 'negative';
        }

        return md;
    }

    // ── Compute direction signal for an objective ──

    private static void computeDirection(ObjectiveDigest od, MetricDigest linked) {
        String rating = linked.performanceRating;
        Decimal weight = od.currentWeight != null ? od.currentWeight : 0;
        Decimal avg = linked.avgValue != null ? linked.avgValue : 0;

        if (rating == 'negative' || rating == 'weak') {
            if (weight >= 5) {
                od.suggestedDirection = 'decrease';
                od.directionRationale = 'Metric is ' + rating + ' (avg '
                    + avg.setScale(1) + '%) despite high weight (' + weight
                    + ') — objective may be counterproductive at this level.';
            } else {
                od.suggestedDirection = 'maintain';
                od.directionRationale = 'Metric is ' + rating + ' (avg '
                    + avg.setScale(1) + '%) but weight is already low ('
                    + weight + ') — reducing further unlikely to help.';
            }
        } else if (rating == 'strong') {
            if (weight <= 3) {
                od.suggestedDirection = 'increase';
                od.directionRationale = 'Metric is strong (avg '
                    + avg.setScale(1) + '%) with low weight ('
                    + weight + ') — room to emphasize this objective.';
            } else {
                od.suggestedDirection = 'maintain';
                od.directionRationale = 'Metric is strong (avg '
                    + avg.setScale(1) + '%) with adequate weight ('
                    + weight + ') — currently well-balanced.';
            }
        } else {
            // moderate
            if (weight < 5) {
                od.suggestedDirection = 'increase';
                od.directionRationale = 'Metric is moderate (avg '
                    + avg.setScale(1) + '%) with low weight ('
                    + weight + ') — could benefit from more emphasis.';
            } else {
                od.suggestedDirection = 'maintain';
                od.directionRationale = 'Metric is moderate (avg '
                    + avg.setScale(1) + '%) with weight ' + weight
                    + ' — reasonably balanced.';
            }
        }
    }

    // ── Generate key findings from digest ──

    private static List<String> generateKeyFindings(PolicyDigest digest) {
        List<String> findings = new List<String>();

        MetricDigest best = null;
        MetricDigest worst = null;
        for (MetricDigest md : digest.metrics) {
            if (best == null || md.avgValue > best.avgValue) best = md;
            if (worst == null || md.avgValue < worst.avgValue) worst = md;
        }

        if (best != null) {
            findings.add('Strongest metric: ' + best.metricName + ' (avg '
                + best.avgValue.setScale(1) + '%, ' + best.performanceRating + ').');
        }
        if (worst != null && worst != best) {
            findings.add('Weakest metric: ' + worst.metricName + ' (avg '
                + worst.avgValue.setScale(1) + '%, ' + worst.performanceRating + ').');
        }

        // Flag mismatches: high weight + poor performance
        for (ObjectiveDigest od : digest.objectives) {
            if (od.hasMeasurableData && od.suggestedDirection == 'decrease') {
                findings.add('Mismatch: ' + od.objectiveName + ' has weight '
                    + od.currentWeight + ' but its metric is underperforming.');
            }
        }

        // Flag opportunities: low weight + strong performance
        for (ObjectiveDigest od : digest.objectives) {
            if (od.hasMeasurableData && od.suggestedDirection == 'increase'
                && od.currentWeight != null && od.currentWeight <= 3) {
                findings.add('Opportunity: ' + od.objectiveName + ' shows strong results with low weight — consider increasing.');
            }
        }

        // Flag volatile metrics
        for (MetricDigest md : digest.metrics) {
            if (md.variance > 15) {
                findings.add('High volatility: ' + md.metricName + ' varies significantly across runs (std dev '
                    + md.variance.setScale(1) + '%).');
            }
        }

        return findings;
    }

    // ── Build System Prompt (focused on interpretation, not calculation) ──

    @TestVisible
    private static String buildSystemPrompt() {
        return 'You are a Salesforce Field Service scheduling optimization advisor.\n\n'
            + 'You will receive a PRE-COMPUTED analysis digest. The numerical analysis (averages, trends, '
            + 'variance, performance ratings, and directional signals) has already been calculated by the system. '
            + 'Do NOT recalculate metrics. Focus on interpreting the analysis and recommending specific weight values.\n\n'
            + 'Your job:\n'
            + '1. Review the per-metric performance ratings and per-objective direction signals\n'
            + '2. Consider tradeoffs between competing objectives:\n'
            + '   - Increasing ASAP (schedule rate) weight often reduces travel efficiency\n'
            + '   - Increasing travel minimization weight may reduce schedule rate\n'
            + '   - Preferred resource constraints can conflict with all other objectives\n'
            + '   - Overtime and gap minimization are generally complementary\n'
            + '3. Choose specific weight values (1-10 scale) for each objective\n'
            + '4. For objectives marked "insufficient_data", keep the current weight unless you have a '
            + 'strong reason based on other objectives to adjust\n'
            + '5. Set confidence based on: runs analyzed (more = higher), variance (lower = higher), data coverage\n\n'
            + 'Respond ONLY with a JSON object in this exact format (no markdown, no code fences):\n'
            + '{\n'
            + '  "recommendations": [\n'
            + '    {\n'
            + '      "objectiveId": "the objective ID from the digest",\n'
            + '      "objectiveName": "objective name",\n'
            + '      "objectiveType": "objective type",\n'
            + '      "currentWeight": 5,\n'
            + '      "recommendedWeight": 7,\n'
            + '      "reasoning": "interpretation referencing the digest data"\n'
            + '    }\n'
            + '  ],\n'
            + '  "summary": "2-3 sentence overall analysis",\n'
            + '  "confidence": "high|medium|low"\n'
            + '}';
    }

    // ── Call LLM via Models API ──

    @TestVisible
    private static String callLlm(String systemPrompt, String userPrompt) {
        aiplatform.ModelsAPI_GenerationRequest genReq = new aiplatform.ModelsAPI_GenerationRequest();
        genReq.prompt = systemPrompt + '\n\n' + userPrompt;

        aiplatform.ModelsAPI.createGenerations_Request req = new aiplatform.ModelsAPI.createGenerations_Request();
        req.modelName = 'sfdc_ai__DefaultGPT4Omni';
        req.body = genReq;

        aiplatform.ModelsAPI api = new aiplatform.ModelsAPI();
        aiplatform.ModelsAPI.createGenerations_Response res = api.createGenerations(req);

        if (res.Code200 == null || res.Code200.generation == null ||
            String.isBlank(res.Code200.generation.generatedText)) {
            throw new AuraHandledException('LLM returned no response');
        }

        return res.Code200.generation.generatedText;
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
            result.summary = llmResponse;
            result.confidence = 'low';
        }

        return result;
    }

    // ── Validate and Sanitize LLM Output ──

    @TestVisible
    private static RecommendationResult validateResponse(
        RecommendationResult result,
        OptimizationAnalysisService.AnalysisResult analysis
    ) {
        // Build lookup of valid objectives
        Map<String, OptimizationAnalysisService.ObjectiveWeight> validObjectives =
            new Map<String, OptimizationAnalysisService.ObjectiveWeight>();
        if (analysis.currentWeights != null) {
            for (OptimizationAnalysisService.ObjectiveWeight ow : analysis.currentWeights) {
                validObjectives.put(ow.objectiveId, ow);
            }
        }

        // Filter out invalid objectiveIds and clamp weights
        Set<String> coveredIds = new Set<String>();
        List<WeightRecommendation> validated = new List<WeightRecommendation>();
        if (result.recommendations != null) {
            for (WeightRecommendation wr : result.recommendations) {
                if (!validObjectives.containsKey(wr.objectiveId)) {
                    continue; // Remove hallucinated objectives
                }

                // Clamp weight to 1-10
                OptimizationAnalysisService.ObjectiveWeight source = validObjectives.get(wr.objectiveId);
                if (wr.recommendedWeight == null) {
                    wr.recommendedWeight = source.weight;
                } else if (wr.recommendedWeight < 1) {
                    wr.recommendedWeight = 1;
                } else if (wr.recommendedWeight > 10) {
                    wr.recommendedWeight = 10;
                }

                coveredIds.add(wr.objectiveId);
                validated.add(wr);
            }
        }

        // Fill missing objectives — keep current weight
        for (String objId : validObjectives.keySet()) {
            if (!coveredIds.contains(objId)) {
                OptimizationAnalysisService.ObjectiveWeight ow = validObjectives.get(objId);
                WeightRecommendation wr = new WeightRecommendation();
                wr.objectiveId = ow.objectiveId;
                wr.objectiveName = ow.objectiveName;
                wr.objectiveType = ow.objectiveType;
                wr.currentWeight = ow.weight;
                wr.recommendedWeight = ow.weight;
                wr.reasoning = 'No change recommended — maintaining current weight.';
                validated.add(wr);
            }
        }

        result.recommendations = validated;

        // Default confidence if missing
        if (String.isBlank(result.confidence)) {
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

    private static Decimal getMetricValue(OptimizationAnalysisService.RunMetrics rm, String fieldName) {
        if (fieldName == 'scheduleRateDelta') return rm.scheduleRateDelta != null ? rm.scheduleRateDelta : 0;
        if (fieldName == 'travelEfficiency') return rm.travelEfficiency != null ? rm.travelEfficiency : 0;
        if (fieldName == 'overtimeReduction') return rm.overtimeReduction != null ? rm.overtimeReduction : 0;
        if (fieldName == 'utilizationDelta') return rm.utilizationDelta != null ? rm.utilizationDelta : 0;
        if (fieldName == 'preferredResourceRate') return rm.preferredResourceRate != null ? rm.preferredResourceRate : 0;
        return 0;
    }

    @TestVisible
    private static String computeTrend(List<Decimal> values) {
        if (values.size() < 4) return 'stable';

        Integer half = values.size() / 2;
        Decimal firstSum = 0;
        Decimal secondSum = 0;
        for (Integer i = 0; i < half; i++) {
            firstSum += values[i];
        }
        for (Integer i = half; i < values.size(); i++) {
            secondSum += values[i];
        }
        Decimal firstAvg = firstSum / half;
        Decimal secondAvg = secondSum / (values.size() - half);

        if (secondAvg > firstAvg + 1) return 'improving';
        if (secondAvg < firstAvg - 1) return 'declining';
        return 'stable';
    }

    @TestVisible
    private static Decimal computeStdDev(List<Decimal> values, Decimal mean) {
        if (values.size() <= 1) return 0;

        Decimal sumSquares = 0;
        for (Decimal v : values) {
            Decimal diff = v - mean;
            sumSquares += diff * diff;
        }
        return (Decimal) Math.sqrt((Double)(sumSquares / values.size()));
    }
}
