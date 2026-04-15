public with sharing class OptimizationAnalysisService {

    // ── Wrapper Classes ──

    public class AnalysisResult {
        @AuraEnabled public String policyId;
        @AuraEnabled public String policyName;
        @AuraEnabled public List<ObjectiveWeight> currentWeights;
        @AuraEnabled public List<RunMetrics> runs;
        @AuraEnabled public AggregateMetrics aggregates;
        @AuraEnabled public Integer totalRunsAnalyzed;
    }

    public class ObjectiveWeight {
        @AuraEnabled public String objectiveId;
        @AuraEnabled public String objectiveName;
        @AuraEnabled public String objectiveType;
        @AuraEnabled public Decimal weight;

        public ObjectiveWeight(String objectiveId, String objectiveName, String objectiveType, Decimal weight) {
            this.objectiveId = objectiveId;
            this.objectiveName = objectiveName;
            this.objectiveType = objectiveType;
            this.weight = weight;
        }
    }

    public class RunMetrics {
        @AuraEnabled public String optimizationRequestId;
        @AuraEnabled public String optimizationRequestName;
        @AuraEnabled public Datetime runDate;
        @AuraEnabled public Decimal scheduleRateDelta;
        @AuraEnabled public Decimal utilizationDelta;
        @AuraEnabled public Decimal travelEfficiency;
        @AuraEnabled public Decimal overtimeReduction;
        @AuraEnabled public Decimal preferredResourceRate;
        @AuraEnabled public Decimal unscheduledRuleViolations;
        @AuraEnabled public Decimal unscheduledLimitedAvailability;
        @AuraEnabled public Decimal scheduledAfter;
        @AuraEnabled public Decimal scheduledBefore;
        @AuraEnabled public Decimal totalOptimizable;
        @AuraEnabled public Decimal utilizationAfter;
        @AuraEnabled public Decimal utilizationBefore;
        @AuraEnabled public Decimal travelTimeAfter;
        @AuraEnabled public Decimal travelTimeBefore;
        @AuraEnabled public Decimal overtimeAfter;
        @AuraEnabled public Decimal overtimeBefore;
        @AuraEnabled public Decimal preferredAfter;
        @AuraEnabled public Decimal preferredBefore;
    }

    public class AggregateMetrics {
        @AuraEnabled public Decimal avgScheduleRateDelta;
        @AuraEnabled public Decimal avgUtilizationDelta;
        @AuraEnabled public Decimal avgTravelEfficiency;
        @AuraEnabled public Decimal avgOvertimeReduction;
        @AuraEnabled public Decimal avgPreferredResourceRate;
        @AuraEnabled public Decimal avgUnscheduledRuleViolations;
        @AuraEnabled public Decimal avgUnscheduledLimitedAvailability;
        @AuraEnabled public String trend; // 'improving', 'declining', 'stable'
    }

    // ── Main Analysis Method ──

    @AuraEnabled(cacheable=true)
    public static AnalysisResult analyzePolicy(String schedulingPolicyId) {
        AnalysisResult result = new AnalysisResult();
        result.policyId = schedulingPolicyId;

        // Get policy name
        FSL__Scheduling_Policy__c policy = [
            SELECT Id, Name
            FROM FSL__Scheduling_Policy__c
            WHERE Id = :schedulingPolicyId
            LIMIT 1
        ];
        result.policyName = policy.Name;

        // Get current objective weights
        result.currentWeights = getCurrentWeights(schedulingPolicyId);

        // Get completed optimization requests for this policy
        List<FSL__Optimization_Request__c> optRequests = [
            SELECT Id, Name, FSL__Start__c, FSL__Finish__c, FSL__Status__c,
                   FSL__Scheduling_Policy__c, CreatedDate
            FROM FSL__Optimization_Request__c
            WHERE FSL__Scheduling_Policy__c = :schedulingPolicyId
              AND FSL__Status__c = 'Completed'
            ORDER BY CreatedDate ASC
            LIMIT 200
        ];

        if (optRequests.isEmpty()) {
            result.runs = new List<RunMetrics>();
            result.aggregates = new AggregateMetrics();
            result.totalRunsAnalyzed = 0;
            return result;
        }

        // Get territory optimization requests for all these optimization requests
        Set<Id> optRequestIds = new Set<Id>();
        for (FSL__Optimization_Request__c orr : optRequests) {
            optRequestIds.add(orr.Id);
        }

        List<FSL__Territory_Optimization_Request__c> territoryRequests = [
            SELECT Id,
                   FSL__Optimization_Request__c,
                   FSL__ServiceTerritory__c,
                   FSL__TotalNumberOfOptimizableServices__c,
                   FSL__TotalNumberOfScheduledServicesBefore__c,
                   FSL__TotalNumberOfScheduledServicesAfter__c,
                   FSL__NumOfScheduledSasToResourcesBefore__c,
                   FSL__NumOfScheduledSasToResourcesAfter__c,
                   FSL__UtilizationTotalBefore__c,
                   FSL__UtilizationTotalAfter__c,
                   FSL__UtilizationWrenchBefore__c,
                   FSL__UtilizationWrenchAfter__c,
                   FSL__TotalTravelTimeBefore__c,
                   FSL__TotalTravelTimeAfter__c,
                   FSL__AvgTravelTimeBefore__c,
                   FSL__AvgTravelTimeAfter__c,
                   FSL__TotalTravelTimeWithoutHomeBefore__c,
                   FSL__TotalTravelTimeWithoutHomeAfter__c,
                   FSL__TotalScheduledTimeOnOvertimeBefore__c,
                   FSL__TotalScheduledTimeOnOvertimeAfter__c,
                   FSL__NumberOfSasSchedToPreferredSrBefore__c,
                   FSL__NumberOfSasSchedToPreferredSrAfter__c,
                   FSL__NumberOfSasWithPreferredResource__c,
                   FSL__UnscheduledServicesRuleViolation__c,
                   FSL__UnscheduledServicesLimitedAvailability__c,
                   FSL__TotalWorkCapacity__c,
                   FSL__TotalWorkDurationScheduledBefore__c,
                   FSL__TotalWorkDurationScheduledAfter__c
            FROM FSL__Territory_Optimization_Request__c
            WHERE FSL__Optimization_Request__c IN :optRequestIds
        ];

        // Group territory requests by optimization request
        Map<Id, List<FSL__Territory_Optimization_Request__c>> torByOr = new Map<Id, List<FSL__Territory_Optimization_Request__c>>();
        for (FSL__Territory_Optimization_Request__c tor : territoryRequests) {
            if (!torByOr.containsKey(tor.FSL__Optimization_Request__c)) {
                torByOr.put(tor.FSL__Optimization_Request__c, new List<FSL__Territory_Optimization_Request__c>());
            }
            torByOr.get(tor.FSL__Optimization_Request__c).add(tor);
        }

        // Compute per-run metrics
        result.runs = new List<RunMetrics>();
        for (FSL__Optimization_Request__c orr : optRequests) {
            List<FSL__Territory_Optimization_Request__c> tors = torByOr.get(orr.Id);
            if (tors == null || tors.isEmpty()) {
                continue;
            }
            RunMetrics rm = computeRunMetrics(orr, tors);
            result.runs.add(rm);
        }

        result.totalRunsAnalyzed = result.runs.size();

        // Compute aggregates
        result.aggregates = computeAggregates(result.runs);

        return result;
    }

    // ── Helper: Get current objective weights for a policy ──

    public static List<ObjectiveWeight> getCurrentWeights(String schedulingPolicyId) {
        List<ObjectiveWeight> weights = new List<ObjectiveWeight>();

        List<FSL__Scheduling_Policy_Goal__c> policyGoals = [
            SELECT Id, FSL__Scheduling_Policy__c, FSL__Service_Goal__c,
                   FSL__Weight__c, FSL__Service_Goal__r.Name,
                   FSL__Service_Goal__r.RecordType.DeveloperName
            FROM FSL__Scheduling_Policy_Goal__c
            WHERE FSL__Scheduling_Policy__c = :schedulingPolicyId
        ];

        for (FSL__Scheduling_Policy_Goal__c pg : policyGoals) {
            String objType = pg.FSL__Service_Goal__r.RecordType.DeveloperName;
            if (objType != null && objType.startsWith('FSL__')) {
                objType = objType.substringAfter('FSL__');
            }
            weights.add(new ObjectiveWeight(
                pg.FSL__Service_Goal__c,
                pg.FSL__Service_Goal__r.Name,
                objType,
                pg.FSL__Weight__c
            ));
        }

        return weights;
    }

    // ── Helper: Compute metrics for a single optimization run ──

    private static RunMetrics computeRunMetrics(
        FSL__Optimization_Request__c orr,
        List<FSL__Territory_Optimization_Request__c> tors
    ) {
        RunMetrics rm = new RunMetrics();
        rm.optimizationRequestId = orr.Id;
        rm.optimizationRequestName = orr.Name;
        rm.runDate = orr.CreatedDate;

        Decimal totalOptimizable = 0;
        Decimal totalScheduledBefore = 0;
        Decimal totalScheduledAfter = 0;
        Decimal totalUtilBefore = 0;
        Decimal totalUtilAfter = 0;
        Decimal totalTravelBefore = 0;
        Decimal totalTravelAfter = 0;
        Decimal totalOvertimeBefore = 0;
        Decimal totalOvertimeAfter = 0;
        Decimal totalPreferredBefore = 0;
        Decimal totalPreferredAfter = 0;
        Decimal totalRuleViolations = 0;
        Decimal totalLimitedAvail = 0;
        Integer territoryCount = tors.size();

        for (FSL__Territory_Optimization_Request__c tor : tors) {
            totalOptimizable += safe(tor.FSL__TotalNumberOfOptimizableServices__c);
            totalScheduledBefore += safe(tor.FSL__NumOfScheduledSasToResourcesBefore__c);
            totalScheduledAfter += safe(tor.FSL__NumOfScheduledSasToResourcesAfter__c);
            totalUtilBefore += safe(tor.FSL__UtilizationTotalBefore__c);
            totalUtilAfter += safe(tor.FSL__UtilizationTotalAfter__c);
            totalTravelBefore += safe(tor.FSL__TotalTravelTimeBefore__c);
            totalTravelAfter += safe(tor.FSL__TotalTravelTimeAfter__c);
            totalOvertimeBefore += safe(tor.FSL__TotalScheduledTimeOnOvertimeBefore__c);
            totalOvertimeAfter += safe(tor.FSL__TotalScheduledTimeOnOvertimeAfter__c);
            totalPreferredBefore += safe(tor.FSL__NumberOfSasSchedToPreferredSrBefore__c);
            totalPreferredAfter += safe(tor.FSL__NumberOfSasSchedToPreferredSrAfter__c);
            totalRuleViolations += safe(tor.FSL__UnscheduledServicesRuleViolation__c);
            totalLimitedAvail += safe(tor.FSL__UnscheduledServicesLimitedAvailability__c);
        }

        rm.scheduledBefore = totalScheduledBefore;
        rm.scheduledAfter = totalScheduledAfter;
        rm.totalOptimizable = totalOptimizable;
        rm.utilizationBefore = territoryCount > 0 ? totalUtilBefore / territoryCount : 0;
        rm.utilizationAfter = territoryCount > 0 ? totalUtilAfter / territoryCount : 0;
        rm.travelTimeBefore = totalTravelBefore;
        rm.travelTimeAfter = totalTravelAfter;
        rm.overtimeBefore = totalOvertimeBefore;
        rm.overtimeAfter = totalOvertimeAfter;
        rm.preferredBefore = totalPreferredBefore;
        rm.preferredAfter = totalPreferredAfter;
        rm.unscheduledRuleViolations = totalRuleViolations;
        rm.unscheduledLimitedAvailability = totalLimitedAvail;

        rm.scheduleRateDelta = totalOptimizable > 0
            ? ((totalScheduledAfter - totalScheduledBefore) / totalOptimizable) * 100
            : 0;

        rm.utilizationDelta = rm.utilizationAfter - rm.utilizationBefore;

        rm.travelEfficiency = totalTravelBefore > 0
            ? ((totalTravelBefore - totalTravelAfter) / totalTravelBefore) * 100
            : 0;

        rm.overtimeReduction = totalOvertimeBefore > 0
            ? ((totalOvertimeBefore - totalOvertimeAfter) / totalOvertimeBefore) * 100
            : 0;

        rm.preferredResourceRate = totalScheduledAfter > 0
            ? (totalPreferredAfter / totalScheduledAfter) * 100
            : 0;

        return rm;
    }

    // ── Helper: Compute aggregate metrics across all runs ──

    private static AggregateMetrics computeAggregates(List<RunMetrics> runs) {
        AggregateMetrics agg = new AggregateMetrics();
        if (runs.isEmpty()) {
            agg.trend = 'stable';
            return agg;
        }

        Decimal sumScheduleRate = 0;
        Decimal sumUtilization = 0;
        Decimal sumTravel = 0;
        Decimal sumOvertime = 0;
        Decimal sumPreferred = 0;
        Decimal sumRuleViolations = 0;
        Decimal sumLimitedAvail = 0;

        for (RunMetrics rm : runs) {
            sumScheduleRate += safe(rm.scheduleRateDelta);
            sumUtilization += safe(rm.utilizationDelta);
            sumTravel += safe(rm.travelEfficiency);
            sumOvertime += safe(rm.overtimeReduction);
            sumPreferred += safe(rm.preferredResourceRate);
            sumRuleViolations += safe(rm.unscheduledRuleViolations);
            sumLimitedAvail += safe(rm.unscheduledLimitedAvailability);
        }

        Integer count = runs.size();
        agg.avgScheduleRateDelta = sumScheduleRate / count;
        agg.avgUtilizationDelta = sumUtilization / count;
        agg.avgTravelEfficiency = sumTravel / count;
        agg.avgOvertimeReduction = sumOvertime / count;
        agg.avgPreferredResourceRate = sumPreferred / count;
        agg.avgUnscheduledRuleViolations = sumRuleViolations / count;
        agg.avgUnscheduledLimitedAvailability = sumLimitedAvail / count;

        if (count >= 4) {
            Integer half = count / 2;
            Decimal firstHalfUtil = 0;
            Decimal secondHalfUtil = 0;
            for (Integer i = 0; i < half; i++) {
                firstHalfUtil += safe(runs[i].utilizationDelta);
            }
            for (Integer i = half; i < count; i++) {
                secondHalfUtil += safe(runs[i].utilizationDelta);
            }
            firstHalfUtil = firstHalfUtil / half;
            secondHalfUtil = secondHalfUtil / (count - half);

            if (secondHalfUtil > firstHalfUtil + 1) {
                agg.trend = 'improving';
            } else if (secondHalfUtil < firstHalfUtil - 1) {
                agg.trend = 'declining';
            } else {
                agg.trend = 'stable';
            }
        } else {
            agg.trend = 'stable';
        }

        return agg;
    }

    // ── Null-safe decimal helper ──

    private static Decimal safe(Decimal val) {
        return val == null ? 0 : val;
    }
}
