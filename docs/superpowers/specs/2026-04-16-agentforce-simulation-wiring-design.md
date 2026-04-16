# Agentforce LLM-Driven Weight Recommendations — Design Spec

**Goal:** Replace the hardcoded simulation engine with LLM-based reasoning so both the Agentforce agent and the LWC analyze real historical optimization data and recommend weight changes grounded in actual patterns — not static formulas.

**Architecture:** Create a Prompt Template that takes historical analysis data and returns structured weight recommendations. Expose it via an Apex service callable from both the LWC and Agentforce. Update the Topic to auto-chain analyze → LLM recommend → apply. The LWC retains all visual metrics (radar, trends, performance overview charts).

**Tech Stack:** Prompt Template, ConnectApi.EinsteinLlm, Apex, GenAiFunction, GenAiPlugin metadata, LWC.

---

## What's Being Replaced

The current `WeightSimulationService` uses a hardcoded impact matrix — static coefficients like "increasing Minimize_Travel weight by 1 improves travel by 1.8%." Candidate scenarios are scored deterministically against these coefficients. This is linear, artificial, and produces the same recommendations regardless of what the data actually shows.

The new approach: the LLM receives the full historical optimization data (per-run before/after metrics, current weights, aggregates, trends) and reasons about actual patterns to identify weaknesses and recommend changes.

---

## Components

### 1. Prompt Template: `Scheduling_Weight_Recommendation`

**Type:** `einstein_gpt__flex` (Flex template — accepts structured input, returns structured output)

**Input:** The full analysis JSON from `OptimizationAnalysisService.analyzePolicy()`, containing:
- Current objective weights (name, type, weight on 1-10 scale)
- Per-run metrics: scheduled before/after, utilization before/after, travel time before/after, overtime before/after, preferred resource before/after, rule violations, limited availability
- Aggregate averages across all runs
- Trend direction (improving/declining/stable)
- Total runs analyzed

**System prompt guidance:**
- You are a Salesforce Field Service scheduling optimization expert
- Analyze the historical optimization data to identify which metrics are underperforming and which objectives may be over- or under-weighted
- Ground every recommendation in specific data points (e.g., "travel efficiency averages -2.3% across 8 runs while Minimize_Travel is weighted only 3 — increasing it should reduce wasted travel")
- Return a JSON object with: recommended weights (objectiveId, objectiveName, currentWeight, recommendedWeight, reasoning), overall analysis summary, projected impact description, and a confidence level (high/medium/low based on data volume and consistency)
- Weight scale is 1-10. Only recommend changes where the data supports it. If current weights are performing well, say so.
- Do not use hardcoded formulas. Reason from the actual metric patterns, trends, and relationships visible in the data.

**Output:** Structured JSON parsed by the calling Apex service.

### 2. Apex Service: `WeightRecommendationEngine`

**Purpose:** Replaces `WeightSimulationService` as the recommendation source for both LWC and Agentforce.

**Methods:**
- `@InvocableMethod(label='Get AI Weight Recommendations')` — for Agentforce
  - Input: `schedulingPolicyIdentifier` (String, accepts name or ID)
  - Output: `recommendationJson` (structured recommendations), `summary` (text summary), `confidence` (high/medium/low), `success` (Boolean)
  - Internally: calls `OptimizationAnalysisService.analyzePolicy()`, serializes the result, invokes the Prompt Template via `ConnectApi.EinsteinLlm.generateMessages()`, parses and returns the LLM response

- `@AuraEnabled public static String getRecommendationsForLwc(String schedulingPolicyId)` — for LWC
  - Same logic, returns JSON string for the component

**Key design decisions:**
- Single code path: both the invocable and AuraEnabled methods call the same internal `generateRecommendations(String policyId)` method
- The Prompt Template is invoked by API name, making it swappable/editable without code changes
- Error handling: if the LLM call fails, return a clear error (not a fallback to hardcoded logic)

### 3. Updated GenAiFunction: `Get_AI_Weight_Recommendations`

**Replaces the need for a simulation GenAiFunction.**

**Metadata file:** `force-app/main/default/genAiFunctions/Get_AI_Weight_Recommendations/Get_AI_Weight_Recommendations.genAiFunction-meta.xml`

- **invocationTarget:** `WeightRecommendationEngine`
- **invocationTargetType:** `apex`
- **isConfirmationRequired:** `false` (read-only)
- **isIncludeInProgressIndicator:** `true`
- **progressIndicatorMessage:** `Analyzing optimization data for recommendations...`
- **masterLabel:** `Get AI Weight Recommendations`
- **description:** "Analyzes historical optimization run data using AI to identify underperforming metrics and recommend optimal weight changes. Returns specific weight recommendations with reasoning grounded in actual data patterns."

**Input schema:**
- `schedulingPolicyIdentifier` (required, text) — Policy name or ID

**Output schema:**
- `recommendationJson` (text, displayable, used by planner) — Structured recommendations including per-objective weight changes with reasoning
- `summary` (text, displayable, used by planner) — Natural language summary of findings and recommendations
- `confidence` (text, displayable, used by planner) — Confidence level: high, medium, or low
- `success` (boolean, not displayable, used by planner)

### 4. Updated Topic: `Scheduling_Weight_Optimization`

**Register the new function, remove `Get_Optimization_Run_Details` (redundant — same Apex as Analyze).**

Functions:
1. `Analyze_Scheduling_Policy_Performance` — retrieves historical data
2. `Get_AI_Weight_Recommendations` — LLM-driven recommendations
3. `Apply_Weight_Recommendations` — applies weights (with confirmation)

**Updated scope:**
> You are a Salesforce Field Service scheduling optimization advisor. You analyze historical optimization data and use AI to recommend optimal scheduling objective weights. Lead with actionable, data-grounded recommendations. Present metrics clearly. When a user asks about scheduling policy performance or weight optimization, always retrieve the data first, then get AI recommendations — never suggest weight changes without data backing.

**Updated instructions:**
1. Call `Analyze_Scheduling_Policy_Performance` to retrieve historical optimization data
2. Immediately call `Get_AI_Weight_Recommendations` to get data-driven weight recommendations
3. Present a summary to the user:
   - Key findings: which metrics are strong and which are underperforming
   - Recommended weight changes with the reasoning for each (from the AI analysis)
   - Confidence level and how many runs were analyzed
4. If confidence is high and improvements are identified, recommend applying. If confidence is low or weights are near-optimal, say so.
5. Only call `Apply_Weight_Recommendations` after the user explicitly confirms. Construct the `weightChangesJson` from the recommendation output.
6. After applying, summarize what changed.

### 5. Updated LWC: `schedulingWeightOptimizer`

**What stays the same:**
- Policy selector combobox
- KPI summary cards (avg schedule rate, utilization delta, travel reduction, runs analyzed)
- Radar chart (current weights, overlays recommended after analysis)
- Trend chart (per-run utilization, schedule rate, travel efficiency over time)
- Performance overview bar chart (aggregate metrics)
- Confirmation modal for applying weights

**What changes:**
- "Analyze & Recommend Weights" button now calls `WeightRecommendationEngine.getRecommendationsForLwc()` instead of `WeightSimulationService.simulateForLwc()`
- Recommendation panel displays LLM-generated summary text and per-objective reasoning instead of projected metrics from hardcoded formulas
- Weight comparison table populated from LLM response (objectiveName, currentWeight, recommendedWeight, reasoning)
- Confidence indicator shown (high/medium/low)
- Remove the "Tested X configurations against Y runs" language — replace with AI analysis framing

### 6. Cleanup

- **Remove `WeightSimulationService.cls`** and its test class — no longer used by either interface
- **Remove `genAiFunctions/Get_Optimization_Run_Details/`** — redundant (same Apex as Analyze)
- **Update permission set** — remove `WeightSimulationService`, add `WeightRecommendationEngine`

---

## Files

| File | Change |
|------|--------|
| `classes/WeightRecommendationEngine.cls` | New — Apex service calling Prompt Template via ConnectApi |
| `classes/WeightRecommendationEngine.cls-meta.xml` | New |
| `classes/WeightRecommendationEngineTest.cls` | New — test class |
| `classes/WeightRecommendationEngineTest.cls-meta.xml` | New |
| `promptTemplates/Scheduling_Weight_Recommendation.*` | New — Prompt Template metadata |
| `genAiFunctions/Get_AI_Weight_Recommendations/` | New — GenAiFunction for Agentforce |
| `genAiPlugins/Scheduling_Weight_Optimization/` | Modified — updated functions, scope, instructions |
| `lwc/schedulingWeightOptimizer/schedulingWeightOptimizer.js` | Modified — call new engine, display LLM recommendations |
| `permissionsets/Scheduling_Weight_Optimizer_Access.permissionset-meta.xml` | Modified — swap class access |
| `classes/WeightSimulationService.cls` | Removed |
| `classes/WeightSimulationServiceTest.cls` | Removed |
| `genAiFunctions/Get_Optimization_Run_Details/` | Removed |

---

## Testing

- Deploy all metadata to the org
- **LWC test:** Open the Scheduling Weight Optimizer app page, select a policy, click "Analyze & Recommend Weights" — verify LLM returns recommendations with per-objective reasoning, charts still render, radar overlays recommended weights, apply flow works
- **Agentforce test:** In Agent Builder, test "Analyze the Customer First policy" — agent should auto-chain analyze → recommend → present findings
- **Edge cases:** Policy with no runs (should gracefully report insufficient data), policy with 1 run (low confidence), policy where weights are already optimal
- **Apex tests:** Mock ConnectApi responses, verify input/output serialization, verify error handling
