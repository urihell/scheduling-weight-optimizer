public with sharing class WeightSimulationService {

    // ── Wrapper Classes ──

    public class SimulationResult {
        @AuraEnabled public List<WeightScenario> topScenarios;
        @AuraEnabled public WeightScenario currentScenario;
        @AuraEnabled public WeightScenario bestScenario;
        @AuraEnabled public Integer totalSimulations;
        @AuraEnabled public Integer runsEvaluated;
    }

    public class WeightScenario {
        @AuraEnabled public String name;
        @AuraEnabled public List<WeightEntry> weights;
        @AuraEnabled public Decimal compositeScore;
        @AuraEnabled public Decimal projScheduleRate;
        @AuraEnabled public Decimal projUtilization;
        @AuraEnabled public Decimal projTravel;
        @AuraEnabled public Decimal projOvertime;
        @AuraEnabled public Decimal projPreferred;
    }

    public class WeightEntry {
        @AuraEnabled public String objectiveId;
        @AuraEnabled public String objectiveName;
        @AuraEnabled public String objectiveType;
        @AuraEnabled public Decimal weight;

        public WeightEntry(String oid, String oname, String otype, Decimal w) {
            this.objectiveId = oid;
            this.objectiveName = oname;
            this.objectiveType = otype;
            this.weight = w;
        }
    }

    // ── Invocable for Agentforce ──

    @InvocableMethod(label='Run Weight Simulation'
                     description='Simulates different weight configurations against historical data to find optimal scheduling policy weights')
    public static List<SimulationOutput> runSimulation(List<SimulationInput> inputs) {
        List<SimulationOutput> outputs = new List<SimulationOutput>();
        for (SimulationInput input : inputs) {
            SimulationOutput output = new SimulationOutput();
            try {
                String policyId = resolvePolicyId(input.schedulingPolicyIdentifier);
                if (String.isBlank(policyId)) {
                    output.resultJson = '{"error": "No scheduling policy found"}';
                    output.success = false;
                    outputs.add(output);
                    continue;
                }
                SimulationResult result = simulate(policyId);
                output.resultJson = JSON.serialize(result);
                output.bestScenarioName = result.bestScenario != null ? result.bestScenario.name : 'N/A';
                output.improvementOverCurrent = result.bestScenario != null && result.currentScenario != null
                    ? result.bestScenario.compositeScore - result.currentScenario.compositeScore
                    : 0;
                output.success = true;
            } catch (Exception e) {
                output.resultJson = '{"error": "' + e.getMessage().escapeJava() + '"}';
                output.success = false;
            }
            outputs.add(output);
        }
        return outputs;
    }

    public class SimulationInput {
        @InvocableVariable(required=true label='Scheduling Policy ID or Name')
        public String schedulingPolicyIdentifier;
    }

    public class SimulationOutput {
        @InvocableVariable(label='Simulation Result JSON')
        public String resultJson;
        @InvocableVariable(label='Best Scenario Name')
        public String bestScenarioName;
        @InvocableVariable(label='Projected Improvement')
        public Decimal improvementOverCurrent;
        @InvocableVariable(label='Success')
        public Boolean success;
    }

    // ── AuraEnabled for LWC ──

    @AuraEnabled
    public static String simulateForLwc(String schedulingPolicyId) {
        SimulationResult result = simulate(schedulingPolicyId);
        return JSON.serialize(result);
    }

    // ── Core Simulation Engine ──

    public static SimulationResult simulate(String schedulingPolicyId) {
        OptimizationAnalysisService.AnalysisResult analysis =
            OptimizationAnalysisService.analyzePolicy(schedulingPolicyId);

        SimulationResult result = new SimulationResult();

        if (analysis.runs == null || analysis.runs.isEmpty()) {
            result.topScenarios = new List<WeightScenario>();
            result.totalSimulations = 0;
            result.runsEvaluated = 0;
            return result;
        }

        List<OptimizationAnalysisService.ObjectiveWeight> objectives = analysis.currentWeights;
        List<OptimizationAnalysisService.RunMetrics> runs = analysis.runs;
        result.runsEvaluated = runs.size();

        Map<String, Decimal> currentWeights = new Map<String, Decimal>();
        for (OptimizationAnalysisService.ObjectiveWeight ow : objectives) {
            currentWeights.put(ow.objectiveType, ow.weight != null ? ow.weight : 0);
        }

        // Step 1: Compute data-driven sensitivity from run variance
        Map<String, Decimal> sensitivity = computeSensitivity(runs);

        // Step 2: Compute recency weights (newer runs matter more)
        List<Decimal> recencyWeights = computeRecencyWeights(runs.size());

        // Step 3: Score current configuration against all runs
        result.currentScenario = scoreAgainstAllRuns(
            'Current Configuration', objectives, currentWeights, currentWeights,
            runs, sensitivity, recencyWeights
        );

        // Step 4: Generate candidates and score each against all runs
        List<Map<String, Decimal>> candidates = generateCandidates(objectives, currentWeights);
        List<WeightScenario> all = new List<WeightScenario>();
        all.add(result.currentScenario);

        for (Map<String, Decimal> candidate : candidates) {
            String name = nameScenario(candidate, currentWeights, objectives);
            WeightScenario ws = scoreAgainstAllRuns(
                name, objectives, candidate, currentWeights,
                runs, sensitivity, recencyWeights
            );
            all.add(ws);
        }

        // Sort descending by composite score
        all.sort(new ScenarioComparator());

        // Pick top 5 excluding current
        result.topScenarios = new List<WeightScenario>();
        for (WeightScenario ws : all) {
            if (ws.name != 'Current Configuration' && result.topScenarios.size() < 5) {
                result.topScenarios.add(ws);
            }
        }

        result.bestScenario = result.topScenarios.isEmpty() ? result.currentScenario : result.topScenarios[0];
        result.totalSimulations = all.size();

        return result;
    }

    // ── Data-Driven Sensitivity ──
    // Computes how much each metric varies across runs.
    // High variance = more room for weight tuning to matter.
    // Returns a multiplier per metric (0.5 to 2.0 range).

    private static Map<String, Decimal> computeSensitivity(
        List<OptimizationAnalysisService.RunMetrics> runs
    ) {
        Integer n = runs.size();
        Map<String, Decimal> sens = new Map<String, Decimal>();

        if (n < 2) {
            sens.put('scheduleRate', 1.0);
            sens.put('utilization', 1.0);
            sens.put('travel', 1.0);
            sens.put('overtime', 1.0);
            sens.put('preferred', 1.0);
            return sens;
        }

        // Compute standard deviation for each metric
        Decimal[] sumSR = new Decimal[]{0, 0};
        Decimal[] sumUT = new Decimal[]{0, 0};
        Decimal[] sumTR = new Decimal[]{0, 0};
        Decimal[] sumOT = new Decimal[]{0, 0};
        Decimal[] sumPR = new Decimal[]{0, 0};

        for (OptimizationAnalysisService.RunMetrics rm : runs) {
            Decimal sr = safe(rm.scheduleRateDelta);
            Decimal ut = safe(rm.utilizationDelta);
            Decimal tr = safe(rm.travelEfficiency);
            Decimal ot = safe(rm.overtimeReduction);
            Decimal pr = safe(rm.preferredResourceRate);
            sumSR[0] += sr; sumSR[1] += sr * sr;
            sumUT[0] += ut; sumUT[1] += ut * ut;
            sumTR[0] += tr; sumTR[1] += tr * tr;
            sumOT[0] += ot; sumOT[1] += ot * ot;
            sumPR[0] += pr; sumPR[1] += pr * pr;
        }

        sens.put('scheduleRate', stdDevToSensitivity(sumSR[0], sumSR[1], n));
        sens.put('utilization', stdDevToSensitivity(sumUT[0], sumUT[1], n));
        sens.put('travel', stdDevToSensitivity(sumTR[0], sumTR[1], n));
        sens.put('overtime', stdDevToSensitivity(sumOT[0], sumOT[1], n));
        sens.put('preferred', stdDevToSensitivity(sumPR[0], sumPR[1], n));

        return sens;
    }

    private static Decimal stdDevToSensitivity(Decimal sum, Decimal sumSq, Integer n) {
        Decimal mean = sum / n;
        Decimal variance = (sumSq / n) - (mean * mean);
        Decimal stdDev = variance > 0 ? Math.sqrt(variance) : 0;
        // Map stdDev to sensitivity multiplier:
        // stdDev 0 → 0.5 (low confidence in projections)
        // stdDev 5 → 1.0 (baseline)
        // stdDev 20+ → 2.0 (high variance = high sensitivity)
        Decimal sensitivity = 0.5 + Math.min(1.5, stdDev / 13.0);
        return sensitivity;
    }

    // ── Recency Weights ──
    // Newer runs get more weight. Uses exponential decay.

    private static List<Decimal> computeRecencyWeights(Integer n) {
        List<Decimal> weights = new List<Decimal>();
        Decimal decay = 0.95; // Each older run gets 5% less weight
        Decimal total = 0;

        for (Integer i = 0; i < n; i++) {
            // Runs are ordered ASC by date, so last run = most recent
            Decimal w = (Decimal) Math.pow((Double) decay, (n - 1 - i));
            weights.add(w);
            total += w;
        }

        // Normalize so weights sum to n (preserves scale of averages)
        for (Integer i = 0; i < n; i++) {
            weights.set(i, (weights[i] / total) * n);
        }

        return weights;
    }

    // ── Score a scenario against ALL individual runs ──

    private static WeightScenario scoreAgainstAllRuns(
        String name,
        List<OptimizationAnalysisService.ObjectiveWeight> objectives,
        Map<String, Decimal> candidateWeights,
        Map<String, Decimal> currentWeights,
        List<OptimizationAnalysisService.RunMetrics> runs,
        Map<String, Decimal> sensitivity,
        List<Decimal> recencyWeights
    ) {
        // Compute weight deltas and their projected impact per metric
        Map<String, Map<String, Decimal>> impact = getImpactMatrix();
        Decimal dSR = 0, dUT = 0, dTR = 0, dOT = 0, dPR = 0;

        for (String objType : candidateWeights.keySet()) {
            Decimal newW = candidateWeights.get(objType);
            Decimal oldW = currentWeights.containsKey(objType) ? currentWeights.get(objType) : 0;
            Decimal delta = newW - oldW;
            if (delta == 0) continue;

            Map<String, Decimal> impacts = impact.get(objType);
            if (impacts == null) continue;

            // Scale impact by data-driven sensitivity
            dSR += delta * safeGet(impacts, 'scheduleRate') * sensitivity.get('scheduleRate');
            dUT += delta * safeGet(impacts, 'utilization') * sensitivity.get('utilization');
            dTR += delta * safeGet(impacts, 'travel') * sensitivity.get('travel');
            dOT += delta * safeGet(impacts, 'overtime') * sensitivity.get('overtime');
            dPR += delta * safeGet(impacts, 'preferred') * sensitivity.get('preferred');
        }

        // Score against each run individually with recency weighting
        Decimal totalScore = 0;
        Decimal totalProjSR = 0, totalProjUT = 0, totalProjTR = 0;
        Decimal totalProjOT = 0, totalProjPR = 0;

        for (Integer i = 0; i < runs.size(); i++) {
            OptimizationAnalysisService.RunMetrics rm = runs[i];
            Decimal rw = recencyWeights[i];

            // Project this run's metrics with the weight adjustment
            Decimal projSR = safe(rm.scheduleRateDelta) + dSR;
            Decimal projUT = safe(rm.utilizationDelta) + dUT;
            Decimal projTR = safe(rm.travelEfficiency) + dTR;
            Decimal projOT = safe(rm.overtimeReduction) + dOT;
            Decimal projPR = safe(rm.preferredResourceRate) + dPR;

            // Composite score for this run
            Decimal runScore = projSR * 0.25 + projUT * 0.25 + projTR * 0.20
                             + projOT * 0.15 + projPR * 0.15;

            totalScore += runScore * rw;
            totalProjSR += projSR * rw;
            totalProjUT += projUT * rw;
            totalProjTR += projTR * rw;
            totalProjOT += projOT * rw;
            totalProjPR += projPR * rw;
        }

        // Average (recency weights sum to n, so divide by n)
        Integer n = runs.size();
        WeightScenario ws = new WeightScenario();
        ws.name = name;
        ws.compositeScore = totalScore / n;
        ws.projScheduleRate = totalProjSR / n;
        ws.projUtilization = totalProjUT / n;
        ws.projTravel = totalProjTR / n;
        ws.projOvertime = totalProjOT / n;
        ws.projPreferred = totalProjPR / n;

        ws.weights = new List<WeightEntry>();
        for (OptimizationAnalysisService.ObjectiveWeight ow : objectives) {
            Decimal w = candidateWeights.containsKey(ow.objectiveType)
                ? candidateWeights.get(ow.objectiveType)
                : (ow.weight != null ? ow.weight : 0);
            ws.weights.add(new WeightEntry(ow.objectiveId, ow.objectiveName, ow.objectiveType, w));
        }

        return ws;
    }

    // ── Impact Matrix ──
    // Base coefficients: projected % change per 1-unit weight increase.
    // These are scaled by data-driven sensitivity at scoring time.

    private static Map<String, Map<String, Decimal>> getImpactMatrix() {
        Map<String, Map<String, Decimal>> m = new Map<String, Map<String, Decimal>>();
        m.put('Objective_Minimize_Travel', new Map<String, Decimal>{
            'scheduleRate' => -0.3, 'utilization' => 0.3, 'travel' => 1.8, 'overtime' => 0.2, 'preferred' => -0.4
        });
        m.put('Objective_Asap', new Map<String, Decimal>{
            'scheduleRate' => 1.8, 'utilization' => 0.5, 'travel' => -0.5, 'overtime' => 0.3, 'preferred' => -0.2
        });
        m.put('Objective_Minimize_Overtime', new Map<String, Decimal>{
            'scheduleRate' => -0.3, 'utilization' => 0.3, 'travel' => 0.0, 'overtime' => 1.8, 'preferred' => 0.0
        });
        m.put('Objective_Minimize_Gaps', new Map<String, Decimal>{
            'scheduleRate' => 0.5, 'utilization' => 1.5, 'travel' => 0.4, 'overtime' => 0.2, 'preferred' => 0.0
        });
        m.put('Objective_PreferredEngineer', new Map<String, Decimal>{
            'scheduleRate' => -0.3, 'utilization' => -0.2, 'travel' => -0.8, 'overtime' => 0.0, 'preferred' => 1.8
        });
        m.put('Objective_Resource_Priority', new Map<String, Decimal>{
            'scheduleRate' => 0.4, 'utilization' => 0.3, 'travel' => -0.3, 'overtime' => 0.0, 'preferred' => 0.8
        });
        m.put('Objective_Skill_Level', new Map<String, Decimal>{
            'scheduleRate' => 0.5, 'utilization' => 0.2, 'travel' => -0.3, 'overtime' => 0.0, 'preferred' => 0.4
        });
        m.put('Objective_Skill_Preferences', new Map<String, Decimal>{
            'scheduleRate' => 0.3, 'utilization' => 0.2, 'travel' => -0.3, 'overtime' => 0.0, 'preferred' => 0.5
        });
        m.put('Objective_Same_Site', new Map<String, Decimal>{
            'scheduleRate' => 0.2, 'utilization' => 0.5, 'travel' => 1.2, 'overtime' => 0.0, 'preferred' => 0.0
        });
        return m;
    }

    // ── Candidate Generation ──

    private static List<Map<String, Decimal>> generateCandidates(
        List<OptimizationAnalysisService.ObjectiveWeight> objectives,
        Map<String, Decimal> currentWeights
    ) {
        List<Map<String, Decimal>> candidates = new List<Map<String, Decimal>>();

        // Strategy 1: Single-objective adjustments (+1, +2, +3, -1, -2, -3)
        for (OptimizationAnalysisService.ObjectiveWeight ow : objectives) {
            for (Integer delta : new List<Integer>{1, 2, 3, -1, -2, -3}) {
                Decimal curW = ow.weight != null ? ow.weight : 0;
                Decimal newW = clampWeight(curW + delta);
                if (newW == curW) continue;
                Map<String, Decimal> candidate = cloneWeights(currentWeights);
                candidate.put(ow.objectiveType, newW);
                candidates.add(candidate);
            }
        }

        // Strategy 2: Pairwise adjustments
        for (Integer i = 0; i < objectives.size(); i++) {
            for (Integer j = i + 1; j < objectives.size(); j++) {
                String typeA = objectives[i].objectiveType;
                String typeB = objectives[j].objectiveType;
                Decimal wA = currentWeights.containsKey(typeA) ? currentWeights.get(typeA) : 0;
                Decimal wB = currentWeights.containsKey(typeB) ? currentWeights.get(typeB) : 0;

                // Both up +2
                Map<String, Decimal> bothUp = cloneWeights(currentWeights);
                bothUp.put(typeA, clampWeight(wA + 2));
                bothUp.put(typeB, clampWeight(wB + 2));
                candidates.add(bothUp);

                // A up, B down
                Map<String, Decimal> aUpBDown = cloneWeights(currentWeights);
                aUpBDown.put(typeA, clampWeight(wA + 2));
                aUpBDown.put(typeB, clampWeight(wB - 2));
                candidates.add(aUpBDown);

                // B up, A down
                Map<String, Decimal> bUpADown = cloneWeights(currentWeights);
                bUpADown.put(typeA, clampWeight(wA - 2));
                bUpADown.put(typeB, clampWeight(wB + 2));
                candidates.add(bUpADown);

                // Both up +1 (smaller step)
                Map<String, Decimal> bothUp1 = cloneWeights(currentWeights);
                bothUp1.put(typeA, clampWeight(wA + 1));
                bothUp1.put(typeB, clampWeight(wB + 1));
                candidates.add(bothUp1);
            }
        }

        // Strategy 3: Uniform shifts
        for (Integer delta : new List<Integer>{1, -1, 2, -2}) {
            Map<String, Decimal> uniform = cloneWeights(currentWeights);
            Boolean changed = false;
            for (String objType : uniform.keySet()) {
                Decimal newW = clampWeight(uniform.get(objType) + delta);
                if (newW != uniform.get(objType)) changed = true;
                uniform.put(objType, newW);
            }
            if (changed) candidates.add(uniform);
        }

        // Strategy 4: Extreme single-focus (max one, min others)
        for (OptimizationAnalysisService.ObjectiveWeight ow : objectives) {
            Map<String, Decimal> extreme = new Map<String, Decimal>();
            for (OptimizationAnalysisService.ObjectiveWeight other : objectives) {
                if (other.objectiveType == ow.objectiveType) {
                    extreme.put(other.objectiveType, 10.0);
                } else {
                    extreme.put(other.objectiveType, 1.0);
                }
            }
            candidates.add(extreme);
        }

        return candidates;
    }

    // ── Scenario Naming ──

    private static String nameScenario(
        Map<String, Decimal> candidate,
        Map<String, Decimal> currentWeights,
        List<OptimizationAnalysisService.ObjectiveWeight> objectives
    ) {
        List<String> changes = new List<String>();
        for (OptimizationAnalysisService.ObjectiveWeight ow : objectives) {
            Decimal newW = candidate.containsKey(ow.objectiveType) ? candidate.get(ow.objectiveType) : 0;
            Decimal oldW = currentWeights.containsKey(ow.objectiveType) ? currentWeights.get(ow.objectiveType) : 0;
            Decimal delta = newW - oldW;
            if (delta != 0) {
                String dir = delta > 0 ? '+' : '';
                changes.add(ow.objectiveName + ' ' + dir + delta.intValue());
            }
        }
        return changes.isEmpty() ? 'No Change' : String.join(changes, ', ');
    }

    // ── Comparator ──

    private class ScenarioComparator implements System.Comparator<WeightScenario> {
        public Integer compare(WeightScenario a, WeightScenario b) {
            if (b.compositeScore > a.compositeScore) return 1;
            if (b.compositeScore < a.compositeScore) return -1;
            return 0;
        }
    }

    // ── Utility Methods ──

    private static Decimal clampWeight(Decimal w) {
        return Math.max(1, Math.min(10, w));
    }

    private static Map<String, Decimal> cloneWeights(Map<String, Decimal> weights) {
        return new Map<String, Decimal>(weights);
    }

    private static Decimal safe(Decimal val) {
        return val == null ? 0 : val;
    }

    private static Decimal safeGet(Map<String, Decimal> m, String key) {
        return m.containsKey(key) ? m.get(key) : 0;
    }

    private static String resolvePolicyId(String identifier) {
        if (String.isBlank(identifier)) return null;
        if (identifier instanceof Id) return identifier;
        List<FSL__Scheduling_Policy__c> policies = [
            SELECT Id FROM FSL__Scheduling_Policy__c
            WHERE Name = :identifier LIMIT 1
        ];
        return policies.isEmpty() ? null : policies[0].Id;
    }
}
