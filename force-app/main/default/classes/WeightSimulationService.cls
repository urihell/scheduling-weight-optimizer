public with sharing class WeightSimulationService {

    // ── Impact Model ──
    // Coefficients represent projected % change per 1-unit weight increase (1-10 scale).
    // Calibrated from FSL scheduling engine behavior patterns.

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

    // ── Wrapper Classes ──

    public class SimulationResult {
        @AuraEnabled public List<WeightScenario> topScenarios;
        @AuraEnabled public WeightScenario currentScenario;
        @AuraEnabled public WeightScenario bestScenario;
        @AuraEnabled public Integer totalSimulations;
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
            return result;
        }

        List<OptimizationAnalysisService.ObjectiveWeight> objectives = analysis.currentWeights;
        Map<String, Decimal> currentWeights = new Map<String, Decimal>();
        for (OptimizationAnalysisService.ObjectiveWeight ow : objectives) {
            currentWeights.put(ow.objectiveType, ow.weight != null ? ow.weight : 0);
        }

        Decimal[] baseline = new Decimal[]{
            safe(analysis.aggregates.avgScheduleRateDelta),
            safe(analysis.aggregates.avgUtilizationDelta),
            safe(analysis.aggregates.avgTravelEfficiency),
            safe(analysis.aggregates.avgOvertimeReduction),
            safe(analysis.aggregates.avgPreferredResourceRate)
        };

        // Score current configuration
        result.currentScenario = buildScenario('Current Configuration', objectives, currentWeights, currentWeights, baseline);

        // Generate and score candidates
        List<WeightScenario> all = new List<WeightScenario>();
        all.add(result.currentScenario);

        List<Map<String, Decimal>> candidates = generateCandidates(objectives, currentWeights);
        Integer scenarioNum = 1;
        for (Map<String, Decimal> candidate : candidates) {
            String name = nameScenario(candidate, currentWeights, objectives);
            WeightScenario ws = buildScenario(name, objectives, candidate, currentWeights, baseline);
            all.add(ws);
            scenarioNum++;
        }

        // Sort descending by composite score
        all.sort(new ScenarioComparator());

        // Pick top 5 (excluding current if it reappears)
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

    // ── Scenario Scoring ──

    private static WeightScenario buildScenario(
        String name,
        List<OptimizationAnalysisService.ObjectiveWeight> objectives,
        Map<String, Decimal> candidateWeights,
        Map<String, Decimal> currentWeights,
        Decimal[] baseline
    ) {
        Map<String, Map<String, Decimal>> impact = getImpactMatrix();

        Decimal dSchedule = 0, dUtil = 0, dTravel = 0, dOvertime = 0, dPreferred = 0;

        for (String objType : candidateWeights.keySet()) {
            Decimal newW = candidateWeights.get(objType);
            Decimal oldW = currentWeights.containsKey(objType) ? currentWeights.get(objType) : 0;
            Decimal delta = newW - oldW;
            if (delta == 0) continue;

            Map<String, Decimal> impacts = impact.get(objType);
            if (impacts == null) continue;

            dSchedule  += delta * safeGet(impacts, 'scheduleRate');
            dUtil      += delta * safeGet(impacts, 'utilization');
            dTravel    += delta * safeGet(impacts, 'travel');
            dOvertime  += delta * safeGet(impacts, 'overtime');
            dPreferred += delta * safeGet(impacts, 'preferred');
        }

        WeightScenario ws = new WeightScenario();
        ws.name = name;
        ws.weights = new List<WeightEntry>();
        for (OptimizationAnalysisService.ObjectiveWeight ow : objectives) {
            Decimal w = candidateWeights.containsKey(ow.objectiveType)
                ? candidateWeights.get(ow.objectiveType)
                : (ow.weight != null ? ow.weight : 0);
            ws.weights.add(new WeightEntry(ow.objectiveId, ow.objectiveName, ow.objectiveType, w));
        }

        ws.projScheduleRate = baseline[0] + dSchedule;
        ws.projUtilization  = baseline[1] + dUtil;
        ws.projTravel       = baseline[2] + dTravel;
        ws.projOvertime     = baseline[3] + dOvertime;
        ws.projPreferred    = baseline[4] + dPreferred;

        // Composite: weighted average across all projected metrics
        ws.compositeScore = ws.projScheduleRate * 0.25
                          + ws.projUtilization  * 0.25
                          + ws.projTravel       * 0.20
                          + ws.projOvertime     * 0.15
                          + ws.projPreferred    * 0.15;

        return ws;
    }

    // ── Candidate Generation ──

    private static List<Map<String, Decimal>> generateCandidates(
        List<OptimizationAnalysisService.ObjectiveWeight> objectives,
        Map<String, Decimal> currentWeights
    ) {
        List<Map<String, Decimal>> candidates = new List<Map<String, Decimal>>();

        // Strategy 1: Single-objective adjustments (+1, +2, +3, -1, -2)
        for (OptimizationAnalysisService.ObjectiveWeight ow : objectives) {
            for (Integer delta : new List<Integer>{1, 2, 3, -1, -2}) {
                Decimal newW = clampWeight((ow.weight != null ? ow.weight : 0) + delta);
                if (newW == (ow.weight != null ? ow.weight : 0)) continue;
                Map<String, Decimal> candidate = cloneWeights(currentWeights);
                candidate.put(ow.objectiveType, newW);
                candidates.add(candidate);
            }
        }

        // Strategy 2: Pairwise adjustments (boost two objectives together)
        for (Integer i = 0; i < objectives.size(); i++) {
            for (Integer j = i + 1; j < objectives.size(); j++) {
                String typeA = objectives[i].objectiveType;
                String typeB = objectives[j].objectiveType;
                Decimal wA = currentWeights.containsKey(typeA) ? currentWeights.get(typeA) : 0;
                Decimal wB = currentWeights.containsKey(typeB) ? currentWeights.get(typeB) : 0;

                // Both up
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
            }
        }

        // Strategy 3: All objectives shifted uniformly
        for (Integer delta : new List<Integer>{1, -1, 2}) {
            Map<String, Decimal> uniform = cloneWeights(currentWeights);
            Boolean changed = false;
            for (String objType : uniform.keySet()) {
                Decimal newW = clampWeight(uniform.get(objType) + delta);
                if (newW != uniform.get(objType)) changed = true;
                uniform.put(objType, newW);
            }
            if (changed) candidates.add(uniform);
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

    // ── Comparator for sorting scenarios ──

    private class ScenarioComparator implements System.Comparator<WeightScenario> {
        public Integer compare(WeightScenario a, WeightScenario b) {
            // Descending by compositeScore
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
