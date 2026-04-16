# LLM-Driven Weight Recommendations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded simulation engine with LLM-based reasoning for weight recommendations, shared by both the LWC and Agentforce agent.

**Architecture:** A Prompt Template defines how the LLM should analyze historical optimization data. An Apex service (`WeightRecommendationEngine`) calls the Prompt Template via `ConnectApi.EinsteinLlm`, returning structured recommendations. The LWC button and Agentforce action both invoke this service. The old `WeightSimulationService` is removed.

**Tech Stack:** Apex, ConnectApi.EinsteinLlm, Prompt Template metadata, GenAiFunction/GenAiPlugin metadata, LWC (JavaScript)

---

## File Structure

| File | Responsibility |
|------|---------------|
| `classes/WeightRecommendationEngine.cls` | New Apex service — calls Prompt Template, returns structured recommendations. Dual interface: `@InvocableMethod` for Agentforce, `@AuraEnabled` for LWC. |
| `classes/WeightRecommendationEngineTest.cls` | Test class with ConnectApi mocks |
| `genAiFunctions/Get_AI_Weight_Recommendations/` | New GenAiFunction metadata + input/output schemas |
| `genAiPlugins/Scheduling_Weight_Optimization/` | Modified Topic — new function, rewritten instructions |
| `lwc/schedulingWeightOptimizer/schedulingWeightOptimizer.js` | Modified — swap simulation call for recommendation engine, update result processing |
| `permissionsets/Scheduling_Weight_Optimizer_Access.permissionset-meta.xml` | Modified — swap WeightSimulationService for WeightRecommendationEngine |
| `classes/WeightSimulationService.cls` | Deleted |
| `classes/WeightSimulationServiceTest.cls` | Deleted |
| `genAiFunctions/Get_Optimization_Run_Details/` | Deleted (redundant) |

---

### Task 1: Create WeightRecommendationEngine Apex Service

**Files:**
- Create: `force-app/main/default/classes/WeightRecommendationEngine.cls`
- Create: `force-app/main/default/classes/WeightRecommendationEngine.cls-meta.xml`

- [ ] **Step 1: Create the Apex class meta file**

Create `force-app/main/default/classes/WeightRecommendationEngine.cls-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>63.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 2: Create the Apex class**

Create `force-app/main/default/classes/WeightRecommendationEngine.cls`:

```apex
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
        ConnectApi.EinsteinLlmGenerationInput input = new ConnectApi.EinsteinLlmGenerationInput();

        ConnectApi.WrappedValue systemMessage = new ConnectApi.WrappedValue();
        systemMessage.value = systemPrompt;

        ConnectApi.WrappedValue userMessage = new ConnectApi.WrappedValue();
        userMessage.value = userPrompt;

        input.promptTextorId = userPrompt;
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.maxTokens = 2000;
        input.additionalConfig.applicationName = 'SchedulingWeightOptimizer';

        ConnectApi.EinsteinLlmGenerationOutput output =
            ConnectApi.EinsteinLlm.generateMessages(input);

        if (output.generations == null || output.generations.isEmpty()) {
            throw new AuraHandledException('LLM returned no response');
        }

        return output.generations[0].text;
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
```

- [ ] **Step 3: Deploy and verify compilation**

Run:
```bash
sf project deploy start \
  --source-dir force-app/main/default/classes/WeightRecommendationEngine.cls \
  --source-dir force-app/main/default/classes/WeightRecommendationEngine.cls-meta.xml \
  --target-org udabby@telcoaf.demo --wait 5
```
Expected: `Status: Succeeded`, 1 component deployed.

- [ ] **Step 4: Commit**

```bash
git add force-app/main/default/classes/WeightRecommendationEngine.cls \
       force-app/main/default/classes/WeightRecommendationEngine.cls-meta.xml
git commit -m "feat: add WeightRecommendationEngine — LLM-driven weight recommendations via ConnectApi"
```

---

### Task 2: Create WeightRecommendationEngine Test Class

**Files:**
- Create: `force-app/main/default/classes/WeightRecommendationEngineTest.cls`
- Create: `force-app/main/default/classes/WeightRecommendationEngineTest.cls-meta.xml`

- [ ] **Step 1: Create the test meta file**

Create `force-app/main/default/classes/WeightRecommendationEngineTest.cls-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>63.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 2: Create the test class**

Create `force-app/main/default/classes/WeightRecommendationEngineTest.cls`:

```apex
@isTest
public class WeightRecommendationEngineTest {

    @isTest
    static void testParseValidResponse() {
        // Build a mock analysis result
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

        // Should fall back gracefully — raw response becomes summary
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
```

- [ ] **Step 3: Deploy the test class**

Run:
```bash
sf project deploy start \
  --source-dir force-app/main/default/classes/WeightRecommendationEngineTest.cls \
  --source-dir force-app/main/default/classes/WeightRecommendationEngineTest.cls-meta.xml \
  --target-org udabby@telcoaf.demo --wait 5
```
Expected: `Status: Succeeded`

- [ ] **Step 4: Run the tests**

Run:
```bash
sf apex run test --tests WeightRecommendationEngineTest --result-format human \
  --target-org udabby@telcoaf.demo --wait 5
```
Expected: 5 tests, all PASS (100%).

- [ ] **Step 5: Commit**

```bash
git add force-app/main/default/classes/WeightRecommendationEngineTest.cls \
       force-app/main/default/classes/WeightRecommendationEngineTest.cls-meta.xml
git commit -m "test: add WeightRecommendationEngineTest with response parsing and edge cases"
```

---

### Task 3: Create GenAiFunction for AI Weight Recommendations

**Files:**
- Create: `force-app/main/default/genAiFunctions/Get_AI_Weight_Recommendations/Get_AI_Weight_Recommendations.genAiFunction-meta.xml`
- Create: `force-app/main/default/genAiFunctions/Get_AI_Weight_Recommendations/input/schema.json`
- Create: `force-app/main/default/genAiFunctions/Get_AI_Weight_Recommendations/output/schema.json`

- [ ] **Step 1: Create the GenAiFunction metadata**

Create `force-app/main/default/genAiFunctions/Get_AI_Weight_Recommendations/Get_AI_Weight_Recommendations.genAiFunction-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<GenAiFunction xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>Analyzes historical optimization run data using AI to identify underperforming metrics and recommend optimal weight changes. Returns specific weight recommendations with reasoning grounded in actual data patterns. Use after analyzing policy performance to find better weights.</description>
    <invocationTarget>WeightRecommendationEngine</invocationTarget>
    <invocationTargetType>apex</invocationTargetType>
    <isConfirmationRequired>false</isConfirmationRequired>
    <isIncludeInProgressIndicator>true</isIncludeInProgressIndicator>
    <masterLabel>Get AI Weight Recommendations</masterLabel>
    <progressIndicatorMessage>Analyzing optimization data for recommendations...</progressIndicatorMessage>
</GenAiFunction>
```

- [ ] **Step 2: Create the input schema**

Create `force-app/main/default/genAiFunctions/Get_AI_Weight_Recommendations/input/schema.json`:

```json
{
  "required": ["schedulingPolicyIdentifier"],
  "unevaluatedProperties": false,
  "properties": {
    "schedulingPolicyIdentifier": {
      "title": "schedulingPolicyIdentifier",
      "description": "Name or ID of the scheduling policy to analyze and generate weight recommendations for",
      "lightning:type": "lightning__textType",
      "lightning:isPII": false,
      "copilotAction:isUserInput": false
    }
  },
  "lightning:type": "lightning__objectType"
}
```

- [ ] **Step 3: Create the output schema**

Create `force-app/main/default/genAiFunctions/Get_AI_Weight_Recommendations/output/schema.json`:

```json
{
  "unevaluatedProperties": false,
  "properties": {
    "recommendationJson": {
      "title": "recommendationJson",
      "description": "Structured recommendations including per-objective weight changes with data-driven reasoning, summary, and confidence level",
      "lightning:type": "lightning__textType",
      "lightning:isPII": false,
      "copilotAction:isDisplayable": true,
      "copilotAction:isUsedByPlanner": true
    },
    "summary": {
      "title": "summary",
      "description": "Natural language summary of findings and weight recommendations",
      "lightning:type": "lightning__textType",
      "lightning:isPII": false,
      "copilotAction:isDisplayable": true,
      "copilotAction:isUsedByPlanner": true
    },
    "confidence": {
      "title": "confidence",
      "description": "Confidence level of the recommendations: high, medium, or low",
      "lightning:type": "lightning__textType",
      "lightning:isPII": false,
      "copilotAction:isDisplayable": true,
      "copilotAction:isUsedByPlanner": true
    },
    "success": {
      "title": "success",
      "description": "Whether the recommendation generation completed successfully",
      "lightning:type": "lightning__booleanType",
      "lightning:isPII": false,
      "copilotAction:isDisplayable": false,
      "copilotAction:isUsedByPlanner": true
    }
  },
  "lightning:type": "lightning__objectType"
}
```

- [ ] **Step 4: Deploy the GenAiFunction**

Run:
```bash
sf project deploy start \
  --source-dir force-app/main/default/genAiFunctions/Get_AI_Weight_Recommendations \
  --target-org udabby@telcoaf.demo --wait 5
```
Expected: `Status: Succeeded`

- [ ] **Step 5: Commit**

```bash
git add force-app/main/default/genAiFunctions/Get_AI_Weight_Recommendations/
git commit -m "feat: add Get_AI_Weight_Recommendations GenAiFunction for Agentforce"
```

---

### Task 4: Update Topic (GenAiPlugin) — Add New Function, Rewrite Instructions

**Files:**
- Modify: `force-app/main/default/genAiPlugins/Scheduling_Weight_Optimization/Scheduling_Weight_Optimization.genAiPlugin-meta.xml`

- [ ] **Step 1: Replace the GenAiPlugin metadata**

Replace the entire contents of `force-app/main/default/genAiPlugins/Scheduling_Weight_Optimization/Scheduling_Weight_Optimization.genAiPlugin-meta.xml` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<GenAiPlugin xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>Analyzes historical FSL optimization data and uses AI to recommend optimal scheduling objective weights. Covers performance analysis, AI-driven recommendations, and applying changes.</description>
    <developerName>Scheduling_Weight_Optimization</developerName>
    <genAiFunctions>
        <functionName>Analyze_Scheduling_Policy_Performance</functionName>
    </genAiFunctions>
    <genAiFunctions>
        <functionName>Get_AI_Weight_Recommendations</functionName>
    </genAiFunctions>
    <genAiFunctions>
        <functionName>Apply_Weight_Recommendations</functionName>
    </genAiFunctions>
    <genAiPluginInstructions>
        <description>When a user asks about scheduling policy performance, weight optimization, or improving scheduling outcomes:

1. Call Analyze_Scheduling_Policy_Performance to retrieve historical optimization data for the policy
2. Immediately call Get_AI_Weight_Recommendations with the same policy to get AI-driven weight recommendations based on the historical data patterns
3. Present a concise summary to the user:
   - Key findings: which metrics are strong and which are underperforming, based on the analysis data
   - Recommended weight changes with the specific reasoning for each (from the AI analysis)
   - Confidence level and how many optimization runs were analyzed
4. If confidence is high and improvements are identified, recommend applying the changes. If confidence is low or weights are near-optimal, tell the user their current configuration is working well
5. Only call Apply_Weight_Recommendations after the user explicitly confirms they want to apply. Construct the weightChangesJson from the recommendation output using the objectiveId and recommendedWeight fields
6. After applying, summarize what was changed and suggest running a real optimization to validate

Never suggest weight changes without first calling the analysis and recommendation actions. All recommendations must be grounded in actual historical data.</description>
        <developerName>instruction_analysis_workflow</developerName>
        <masterLabel>Analysis Workflow Instructions</masterLabel>
    </genAiPluginInstructions>
    <language>en_US</language>
    <masterLabel>Scheduling Weight Optimization</masterLabel>
    <pluginType>Topic</pluginType>
    <scope>You are a Salesforce Field Service scheduling optimization advisor. You analyze historical optimization data and use AI to recommend optimal weights for scheduling objectives. Lead with actionable, data-grounded recommendations. Present metrics clearly in tables. When a user asks about scheduling policy performance or weight optimization, always retrieve the data first, then get AI recommendations — never suggest weight changes without data backing.</scope>
</GenAiPlugin>
```

- [ ] **Step 2: Deploy the updated Topic**

Run:
```bash
sf project deploy start \
  --source-dir force-app/main/default/genAiPlugins/Scheduling_Weight_Optimization \
  --target-org udabby@telcoaf.demo --wait 5
```
Expected: `Status: Succeeded`

- [ ] **Step 3: Commit**

```bash
git add force-app/main/default/genAiPlugins/Scheduling_Weight_Optimization/
git commit -m "feat: update Topic with AI recommendations action and auto-chain instructions"
```

---

### Task 5: Update LWC — Swap Simulation for LLM Recommendations

**Files:**
- Modify: `force-app/main/default/lwc/schedulingWeightOptimizer/schedulingWeightOptimizer.js`

- [ ] **Step 1: Update the import statement**

In `schedulingWeightOptimizer.js`, replace:

```javascript
import simulateForLwc from '@salesforce/apex/WeightSimulationService.simulateForLwc';
```

with:

```javascript
import getRecommendationsForLwc from '@salesforce/apex/WeightRecommendationEngine.getRecommendationsForLwc';
```

- [ ] **Step 2: Update handleAnalyzeClick to call the new service**

Replace the `handleAnalyzeClick` method:

```javascript
    async handleAnalyzeClick() {
        this.isAnalyzing = true;
        try {
            const resultJson = await getRecommendationsForLwc({
                schedulingPolicyId: this.selectedPolicyId
            });
            const result = JSON.parse(resultJson);
            this.processRecommendationResults(result);
        } catch (error) {
            this.showToast('Error', 'Recommendation failed: ' + this.extractError(error), 'error');
        } finally {
            this.isAnalyzing = false;
        }
    }
```

- [ ] **Step 3: Replace processSimulationResults with processRecommendationResults**

Replace the entire `processSimulationResults` method with:

```javascript
    processRecommendationResults(result) {
        if (!result || !result.success) {
            this.recommendationText = '<p>' + (result?.error || 'No recommendations available. Ensure the policy has completed optimization runs.') + '</p>';
            return;
        }

        const recs = result.recommendations || [];
        const runsAnalyzed = result.runsAnalyzed || 0;

        // Build weight comparison table
        this.weightComparison = recs.map(r => {
            const curW = Number(r.currentWeight || 0);
            const recW = Number(r.recommendedWeight || 0);
            const change = recW - curW;
            return {
                objectiveId: r.objectiveId,
                objectiveName: r.objectiveName,
                objectiveType: r.objectiveType,
                currentWeight: curW,
                recommendedWeight: recW,
                changeDisplay: change > 0 ? '+' + change : change === 0 ? '\u2014' : '' + change,
                changeClass: change > 0 ? 'change-positive' : change < 0 ? 'change-negative' : 'change-neutral',
                reasoning: r.reasoning || ''
            };
        });

        // Build recommendation text
        const confidenceLabel = (result.confidence || 'medium').charAt(0).toUpperCase() + (result.confidence || 'medium').slice(1);
        let text = '<p><strong>AI Analysis Complete</strong> — ' + runsAnalyzed + ' historical optimization runs analyzed. ';
        text += 'Confidence: <strong>' + confidenceLabel + '</strong></p>';

        if (result.summary) {
            text += '<p style="margin-top:8px">' + result.summary + '</p>';
        }

        // Show per-objective reasoning
        const changedRecs = recs.filter(r => Number(r.recommendedWeight || 0) !== Number(r.currentWeight || 0));
        if (changedRecs.length > 0) {
            text += '<div style="margin-top:12px">';
            for (const r of changedRecs) {
                const arrow = Number(r.recommendedWeight) > Number(r.currentWeight) ? '&#x2191;' : '&#x2193;';
                const color = Number(r.recommendedWeight) > Number(r.currentWeight) ? '#2e844a' : '#ea001e';
                text += '<p style="margin:4px 0"><span style="color:' + color + '">' + arrow + '</span> ';
                text += '<strong>' + r.objectiveName + '</strong> (' + r.currentWeight + ' &rarr; ' + r.recommendedWeight + '): ';
                text += '<span style="color:#706e6b">' + (r.reasoning || '') + '</span></p>';
            }
            text += '</div>';
        } else {
            text += '<p style="margin-top:8px;color:#2e844a"><strong>Your current weights are performing well.</strong> No changes recommended at this time.</p>';
        }

        text += '<p style="margin-top:12px;padding:8px 12px;background:#f3f2f2;border-radius:4px;font-size:12px;color:#706e6b">';
        text += '<strong>Note:</strong> Recommendations are AI-generated based on analysis of historical optimization patterns. ';
        text += 'Apply the recommended weights, run a real optimization, then return here to analyze the results and refine further.</p>';

        this.recommendationText = text;

        if (this.radarChartInstance) {
            this.updateRadarWithRecommendations();
        }
    }
```

- [ ] **Step 4: Update the spinner text in the HTML**

In `schedulingWeightOptimizer.html`, find:

```html
<span class="slds-m-left_medium">Analyzing optimization history...</span>
```

Replace with:

```html
<span class="slds-m-left_medium">AI is analyzing optimization data...</span>
```

- [ ] **Step 5: Deploy the LWC**

Run:
```bash
sf project deploy start \
  --source-dir force-app/main/default/lwc/schedulingWeightOptimizer \
  --target-org udabby@telcoaf.demo --wait 5
```
Expected: `Status: Succeeded`

- [ ] **Step 6: Commit**

```bash
git add force-app/main/default/lwc/schedulingWeightOptimizer/
git commit -m "feat: LWC uses LLM-driven recommendations instead of hardcoded simulation"
```

---

### Task 6: Update Permission Set

**Files:**
- Modify: `force-app/main/default/permissionsets/Scheduling_Weight_Optimizer_Access.permissionset-meta.xml`

- [ ] **Step 1: Swap class access**

In `Scheduling_Weight_Optimizer_Access.permissionset-meta.xml`, replace:

```xml
    <classAccesses>
        <apexClass>WeightSimulationService</apexClass>
        <enabled>true</enabled>
    </classAccesses>
```

with:

```xml
    <classAccesses>
        <apexClass>WeightRecommendationEngine</apexClass>
        <enabled>true</enabled>
    </classAccesses>
```

- [ ] **Step 2: Deploy the permission set**

Run:
```bash
sf project deploy start \
  --source-dir force-app/main/default/permissionsets \
  --target-org udabby@telcoaf.demo --wait 5
```
Expected: `Status: Succeeded`

- [ ] **Step 3: Commit**

```bash
git add force-app/main/default/permissionsets/
git commit -m "chore: update permission set — swap WeightSimulationService for WeightRecommendationEngine"
```

---

### Task 7: Remove Old Simulation Service and Redundant GenAiFunction

**Files:**
- Delete: `force-app/main/default/classes/WeightSimulationService.cls`
- Delete: `force-app/main/default/classes/WeightSimulationService.cls-meta.xml`
- Delete: `force-app/main/default/classes/WeightSimulationServiceTest.cls`
- Delete: `force-app/main/default/classes/WeightSimulationServiceTest.cls-meta.xml`
- Delete: `force-app/main/default/genAiFunctions/Get_Optimization_Run_Details/` (entire directory)

- [ ] **Step 1: Delete the old simulation classes from the org**

Run:
```bash
sf project deploy start \
  --metadata ApexClass:WeightSimulationService \
  --metadata ApexClass:WeightSimulationServiceTest \
  --target-org udabby@telcoaf.demo \
  --purge-on-delete --wait 5
```

Note: If this fails because `--purge-on-delete` doesn't support individual classes, use destructive changes instead:

Create a temporary `destructiveChanges.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>WeightSimulationService</members>
        <members>WeightSimulationServiceTest</members>
        <name>ApexClass</name>
    </types>
    <types>
        <members>Get_Optimization_Run_Details</members>
        <name>GenAiFunction</name>
    </types>
    <version>63.0</version>
</Package>
```

And an empty `package.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <version>63.0</version>
</Package>
```

Run:
```bash
sf project deploy start \
  --manifest package.xml \
  --post-destructive-changes destructiveChanges.xml \
  --target-org udabby@telcoaf.demo --wait 5
```

- [ ] **Step 2: Delete the local files**

```bash
rm force-app/main/default/classes/WeightSimulationService.cls
rm force-app/main/default/classes/WeightSimulationService.cls-meta.xml
rm force-app/main/default/classes/WeightSimulationServiceTest.cls
rm force-app/main/default/classes/WeightSimulationServiceTest.cls-meta.xml
rm -rf force-app/main/default/genAiFunctions/Get_Optimization_Run_Details
```

- [ ] **Step 3: Run all remaining tests to verify nothing is broken**

```bash
sf apex run test \
  --tests OptimizationAnalysisServiceTest \
  --tests WeightRecommendationServiceTest \
  --tests WeightUpdateServiceTest \
  --tests WeightRecommendationEngineTest \
  --result-format human \
  --target-org udabby@telcoaf.demo --wait 5
```
Expected: All tests PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: remove WeightSimulationService and redundant Get_Optimization_Run_Details GenAiFunction"
```

---

### Task 8: End-to-End Verification

- [ ] **Step 1: Deploy entire project to verify clean state**

```bash
sf project deploy start \
  --source-dir force-app \
  --target-org udabby@telcoaf.demo --wait 10
```
Expected: `Status: Succeeded`, all components deploy cleanly.

- [ ] **Step 2: Run all tests**

```bash
sf apex run test --test-level RunLocalTests --result-format human \
  --target-org udabby@telcoaf.demo --wait 10
```
Expected: All tests PASS (100%).

- [ ] **Step 3: Verify Agentforce Topic in Setup**

Open the org → Setup → Agentforce → Topics. Verify:
- `Scheduling Weight Optimization` Topic exists
- 3 actions registered: `Analyze Scheduling Policy Performance`, `Get AI Weight Recommendations`, `Apply Weight Recommendations`
- `Get Optimization Run Details` is no longer listed

- [ ] **Step 4: Test the LWC**

Open the Scheduling Weight Optimizer app page in the org:
1. Select a scheduling policy with completed optimization runs
2. Verify charts render (radar, trends, performance overview)
3. Click "Analyze & Recommend Weights"
4. Verify spinner shows "AI is analyzing optimization data..."
5. Verify recommendations appear with per-objective reasoning
6. Verify radar chart overlays recommended weights
7. Click "Apply Recommendations" → confirm → verify weights update

- [ ] **Step 5: Push to GitHub**

```bash
git push origin main
```
