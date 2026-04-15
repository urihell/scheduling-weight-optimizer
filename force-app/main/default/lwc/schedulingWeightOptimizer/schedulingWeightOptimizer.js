import { LightningElement, api } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import chartjs from '@salesforce/resourceUrl/chartjs';
import analyzePolicy from '@salesforce/apex/OptimizationAnalysisService.analyzePolicy';
import analyzeForLwc from '@salesforce/apex/WeightRecommendationService.analyzeForLwc';
import applyWeightsForLwc from '@salesforce/apex/WeightUpdateService.applyWeightsForLwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class SchedulingWeightOptimizer extends LightningElement {
    @api recordId;

    chartJsLoaded = false;
    isLoading = false;
    isAnalyzing = false;
    isApplying = false;
    showConfirmModal = false;

    analysisResult = null;
    recommendationText = '';
    weightComparison = [];
    policyOptions = [];
    selectedPolicyId = '';
    policyName = '';

    radarChartInstance = null;
    trendChartInstance = null;
    heatmapChartInstance = null;

    get showPolicySelector() {
        return !this.recordId;
    }

    get hasData() {
        return this.analysisResult && this.analysisResult.totalRunsAnalyzed > 0;
    }

    get noData() {
        return !this.isLoading && !this.hasData && (this.selectedPolicyId || this.recordId);
    }

    get hasRecommendation() {
        return this.recommendationText && !this.isAnalyzing;
    }

    get showAnalyzeButton() {
        return !this.hasRecommendation && !this.isAnalyzing && this.hasData;
    }

    get avgScheduleRate() {
        return this.analysisResult?.aggregates?.avgScheduleRateDelta?.toFixed(1) || '0.0';
    }

    get avgUtilizationDelta() {
        return this.analysisResult?.aggregates?.avgUtilizationDelta?.toFixed(1) || '0.0';
    }

    get avgTravelReduction() {
        return this.analysisResult?.aggregates?.avgTravelEfficiency?.toFixed(1) || '0.0';
    }

    get totalRunsAnalyzed() {
        return this.analysisResult?.totalRunsAnalyzed || 0;
    }

    connectedCallback() {
        if (this.recordId) {
            this.selectedPolicyId = this.recordId;
            this.loadAnalysis();
        }
    }

    renderedCallback() {
        if (this.chartJsLoaded) {
            return;
        }
        loadScript(this, chartjs)
            .then(() => {
                this.chartJsLoaded = true;
                if (this.analysisResult) {
                    this.renderCharts();
                }
            })
            .catch(error => {
                this.showToast('Error', 'Failed to load Chart.js: ' + error.message, 'error');
            });
    }

    async loadAnalysis() {
        if (!this.selectedPolicyId) return;

        this.isLoading = true;
        try {
            this.analysisResult = await analyzePolicy({ schedulingPolicyId: this.selectedPolicyId });
            this.policyName = this.analysisResult?.policyName || '';

            if (this.chartJsLoaded && this.analysisResult?.totalRunsAnalyzed > 0) {
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                requestAnimationFrame(() => {
                    this.renderCharts();
                });
            }
        } catch (error) {
            this.showToast('Error', 'Failed to load analysis: ' + this.extractError(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handlePolicyChange(event) {
        this.selectedPolicyId = event.detail.value;
        this.recommendationText = '';
        this.weightComparison = [];
        this.loadAnalysis();
    }

    async handleAnalyzeClick() {
        this.isAnalyzing = true;
        try {
            const resultJson = await analyzeForLwc({
                schedulingPolicyId: this.selectedPolicyId
            });
            const result = JSON.parse(resultJson);

            if (result && result.success) {
                const analysisData = JSON.parse(result.analysisJson);
                this.generateRecommendations(analysisData);
            } else {
                const errorMsg = result?.analysisJson || 'Unknown error';
                this.showToast('Error', 'Analysis failed: ' + errorMsg, 'error');
            }
        } catch (error) {
            this.showToast('Error', 'Analysis failed: ' + this.extractError(error), 'error');
        } finally {
            this.isAnalyzing = false;
        }
    }

    handleApplyClick() {
        this.showConfirmModal = true;
        this._escHandler = (event) => {
            if (event.key === 'Escape') {
                this.handleCancelApply();
            }
        };
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            window.addEventListener('keyup', this._escHandler);
            const modal = this.template.querySelector('.slds-modal__container');
            if (modal) {
                modal.focus();
            }
        });
    }

    handleCancelApply() {
        this.showConfirmModal = false;
        if (this._escHandler) {
            window.removeEventListener('keyup', this._escHandler);
            this._escHandler = null;
        }
    }

    async handleConfirmApply() {
        this.showConfirmModal = false;
        if (this._escHandler) {
            window.removeEventListener('keyup', this._escHandler);
            this._escHandler = null;
        }
        this.isApplying = true;

        try {
            const changes = this.weightComparison
                .filter(row => row.currentWeight !== row.recommendedWeight)
                .map(row => ({
                    objectiveId: row.objectiveId,
                    newWeight: row.recommendedWeight
                }));

            const resultJson = await applyWeightsForLwc({
                schedulingPolicyId: this.selectedPolicyId,
                weightChangesJson: JSON.stringify(changes)
            });
            const result = JSON.parse(resultJson);

            if (result && result.success) {
                this.showToast('Success', result.message, 'success');
                this.recommendationText = '';
                this.weightComparison = [];
                await this.loadAnalysis();
            } else {
                this.showToast('Error', result?.message || 'Failed to apply weights', 'error');
            }
        } catch (error) {
            this.showToast('Error', 'Failed to apply weights: ' + this.extractError(error), 'error');
        } finally {
            this.isApplying = false;
        }
    }

    generateRecommendations(analysisData) {
        const weights = analysisData.currentWeights || [];
        const agg = analysisData.aggregates || {};
        const runs = analysisData.runs || [];

        const recommendations = [];
        this.weightComparison = [];

        for (const w of weights) {
            let recommendedWeight = w.weight || 0;
            let reasoning = '';

            const objType = (w.objectiveType || '').toLowerCase();

            if (objType.includes('travel') || objType.includes('minimize_travel')) {
                if (agg.avgTravelEfficiency < 5) {
                    recommendedWeight = Math.min((w.weight || 0) + 2, 10);
                    reasoning = 'Travel reduction is low — increasing weight to prioritize.';
                } else if (agg.avgTravelEfficiency > 20) {
                    recommendedWeight = Math.max((w.weight || 0) - 1, 1);
                    reasoning = 'Travel reduction is strong — can reduce weight slightly.';
                }
            } else if (objType.includes('overtime') || objType.includes('minimize_overtime')) {
                if (runs.length > 0) {
                    const avgOvertime = runs.reduce((sum, r) => sum + (r.overtimeAfter || 0), 0) / runs.length;
                    if (avgOvertime > 0) {
                        recommendedWeight = Math.min((w.weight || 0) + 2, 10);
                        reasoning = 'Overtime still occurring post-optimization — increase weight.';
                    }
                }
            } else if (objType.includes('asap')) {
                if (agg.avgScheduleRateDelta < 5) {
                    recommendedWeight = Math.min((w.weight || 0) + 1, 10);
                    reasoning = 'Schedule rate improvement is modest — boost ASAP priority.';
                }
            } else if (objType.includes('preferred') || objType.includes('preferredengineer')) {
                if (agg.avgPreferredResourceRate < 50) {
                    recommendedWeight = Math.min((w.weight || 0) + 1, 10);
                    reasoning = 'Preferred resource match rate is below 50% — increase weight.';
                }
            } else if (objType.includes('gap') || objType.includes('minimize_gaps')) {
                if (agg.avgUtilizationDelta < 2) {
                    recommendedWeight = Math.min((w.weight || 0) + 1, 10);
                    reasoning = 'Low utilization improvement — reducing gaps may help.';
                }
            }

            if (!reasoning) {
                reasoning = 'Current weight appears appropriate based on historical data.';
            }

            const change = recommendedWeight - (w.weight || 0);
            let changeDisplay = change > 0 ? '+' + change : change === 0 ? '\u2014' : '' + change;
            let changeClass = change > 0 ? 'change-positive' : change < 0 ? 'change-negative' : 'change-neutral';

            this.weightComparison.push({
                objectiveId: w.objectiveId,
                objectiveName: w.objectiveName,
                objectiveType: w.objectiveType,
                currentWeight: w.weight || 0,
                recommendedWeight: recommendedWeight,
                changeDisplay: changeDisplay,
                changeClass: changeClass
            });

            if (change !== 0) {
                recommendations.push('<li><strong>' + w.objectiveName + '</strong> (' + w.objectiveType + '): ' + reasoning + '</li>');
            }
        }

        let text = '<p><strong>Analysis Summary:</strong> Analyzed ' + (analysisData.totalRunsAnalyzed || 0) + ' optimization runs. ';
        text += 'Trend: <strong>' + (agg.trend || 'stable') + '</strong>.</p>';

        if (recommendations.length > 0) {
            text += '<p><strong>Recommended Changes:</strong></p><ul>' + recommendations.join('') + '</ul>';
        } else {
            text += '<p>Current weights appear well-tuned — no changes recommended.</p>';
        }

        this.recommendationText = text;

        if (this.radarChartInstance) {
            this.updateRadarWithRecommendations();
        }
    }

    renderCharts() {
        this.renderRadarChart();
        this.renderTrendChart();
        this.renderHeatmapChart();
    }

    renderRadarChart() {
        const canvas = this.refs.radarChart;
        if (!canvas || !this.analysisResult?.currentWeights) return;

        if (this.radarChartInstance) {
            this.radarChartInstance.destroy();
        }

        const labels = this.analysisResult.currentWeights.map(w => w.objectiveName);
        const currentData = this.analysisResult.currentWeights.map(w => w.weight || 0);

        this.radarChartInstance = new window.Chart(canvas, {
            type: 'radar',
            data: {
                labels: labels,
                datasets: [{
                    label: 'Current Weights',
                    data: currentData,
                    backgroundColor: 'rgba(1, 118, 211, 0.2)',
                    borderColor: '#0176d3',
                    pointBackgroundColor: '#0176d3',
                    borderWidth: 2
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                scales: {
                    r: {
                        beginAtZero: true,
                        max: 10,
                        ticks: { stepSize: 2 }
                    }
                },
                plugins: {
                    legend: { position: 'bottom' }
                }
            }
        });
    }

    updateRadarWithRecommendations() {
        if (!this.radarChartInstance || !this.weightComparison.length) return;

        const recommendedData = this.weightComparison.map(w => w.recommendedWeight);

        if (this.radarChartInstance.data.datasets.length < 2) {
            this.radarChartInstance.data.datasets.push({
                label: 'Recommended Weights',
                data: recommendedData,
                backgroundColor: 'rgba(46, 132, 74, 0.2)',
                borderColor: '#2e844a',
                pointBackgroundColor: '#2e844a',
                borderWidth: 2,
                borderDash: [5, 5]
            });
        } else {
            this.radarChartInstance.data.datasets[1].data = recommendedData;
        }
        this.radarChartInstance.update();
    }

    renderTrendChart() {
        const canvas = this.refs.trendChart;
        if (!canvas || !this.analysisResult?.runs) return;

        if (this.trendChartInstance) {
            this.trendChartInstance.destroy();
        }

        const runs = this.analysisResult.runs;
        const labels = runs.map((r, i) => r.optimizationRequestName || 'Run ' + (i + 1));

        this.trendChartInstance = new window.Chart(canvas, {
            type: 'line',
            data: {
                labels: labels,
                datasets: [
                    {
                        label: 'Utilization Delta (%)',
                        data: runs.map(r => r.utilizationDelta?.toFixed(2) || 0),
                        borderColor: '#0176d3',
                        backgroundColor: 'rgba(1, 118, 211, 0.1)',
                        fill: true,
                        tension: 0.3
                    },
                    {
                        label: 'Schedule Rate Delta (%)',
                        data: runs.map(r => r.scheduleRateDelta?.toFixed(2) || 0),
                        borderColor: '#2e844a',
                        backgroundColor: 'rgba(46, 132, 74, 0.1)',
                        fill: true,
                        tension: 0.3
                    },
                    {
                        label: 'Travel Efficiency (%)',
                        data: runs.map(r => r.travelEfficiency?.toFixed(2) || 0),
                        borderColor: '#fe5c4c',
                        backgroundColor: 'rgba(254, 92, 76, 0.1)',
                        fill: true,
                        tension: 0.3
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: { position: 'bottom' }
                },
                scales: {
                    y: {
                        title: { display: true, text: 'Improvement (%)' }
                    }
                }
            }
        });
    }

    renderHeatmapChart() {
        const canvas = this.refs.heatmapChart;
        if (!canvas || !this.analysisResult?.runs || !this.analysisResult?.currentWeights) return;

        if (this.heatmapChartInstance) {
            this.heatmapChartInstance.destroy();
        }

        const objectives = this.analysisResult.currentWeights;
        const metrics = ['Utilization', 'Travel', 'Schedule Rate', 'Overtime', 'Preferred Resource'];
        const runs = this.analysisResult.runs;

        const datasets = metrics.map((metric, mIdx) => {
            const colors = ['#0176d3', '#2e844a', '#fe5c4c', '#f38303', '#9050e9'];
            const data = objectives.map(obj => {
                return this.computeCorrelation(obj.objectiveType, metric, runs);
            });

            return {
                label: metric,
                data: data,
                backgroundColor: colors[mIdx],
                borderWidth: 1
            };
        });

        this.heatmapChartInstance = new window.Chart(canvas, {
            type: 'bar',
            data: {
                labels: objectives.map(o => o.objectiveName),
                datasets: datasets
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                indexAxis: 'y',
                plugins: {
                    legend: { position: 'bottom' },
                    title: { display: false }
                },
                scales: {
                    x: {
                        title: { display: true, text: 'Correlation Strength' },
                        min: -1,
                        max: 1
                    }
                }
            }
        });
    }

    computeCorrelation(objectiveType, metric, runs) {
        const type = (objectiveType || '').toLowerCase();
        const avgMetric = this.getAvgMetric(metric, runs);

        const correlationMap = {
            'objective_minimize_travel': { 'Travel': 0.9, 'Utilization': 0.3, 'Schedule Rate': 0.1, 'Overtime': 0.1, 'Preferred Resource': -0.1 },
            'objective_asap': { 'Travel': -0.2, 'Utilization': 0.5, 'Schedule Rate': 0.8, 'Overtime': 0.2, 'Preferred Resource': 0.0 },
            'objective_minimize_overtime': { 'Travel': 0.0, 'Utilization': 0.2, 'Schedule Rate': -0.1, 'Overtime': 0.9, 'Preferred Resource': 0.0 },
            'objective_minimize_gaps': { 'Travel': 0.2, 'Utilization': 0.7, 'Schedule Rate': 0.3, 'Overtime': 0.1, 'Preferred Resource': 0.0 },
            'objective_preferredengineer': { 'Travel': -0.3, 'Utilization': -0.1, 'Schedule Rate': -0.1, 'Overtime': 0.0, 'Preferred Resource': 0.9 },
            'objective_resource_priority': { 'Travel': -0.1, 'Utilization': 0.2, 'Schedule Rate': 0.2, 'Overtime': 0.0, 'Preferred Resource': 0.4 },
            'objective_skill_level': { 'Travel': -0.1, 'Utilization': 0.1, 'Schedule Rate': 0.3, 'Overtime': 0.0, 'Preferred Resource': 0.2 },
            'objective_skill_preferences': { 'Travel': -0.1, 'Utilization': 0.1, 'Schedule Rate': 0.2, 'Overtime': 0.0, 'Preferred Resource': 0.3 },
            'objective_same_site': { 'Travel': 0.6, 'Utilization': 0.3, 'Schedule Rate': 0.1, 'Overtime': 0.0, 'Preferred Resource': 0.0 }
        };

        const typeCorrelations = correlationMap[type] || {};
        let correlation = typeCorrelations[metric] || 0;

        if (avgMetric !== 0) {
            correlation = correlation * (avgMetric > 0 ? 1 : -0.5);
        }

        return parseFloat(correlation.toFixed(2));
    }

    getAvgMetric(metric, runs) {
        if (!runs || runs.length === 0) return 0;
        let sum = 0;
        for (const r of runs) {
            switch (metric) {
                case 'Utilization': sum += r.utilizationDelta || 0; break;
                case 'Travel': sum += r.travelEfficiency || 0; break;
                case 'Schedule Rate': sum += r.scheduleRateDelta || 0; break;
                case 'Overtime': sum += r.overtimeReduction || 0; break;
                case 'Preferred Resource': sum += r.preferredResourceRate || 0; break;
                default: break;
            }
        }
        return sum / runs.length;
    }

    extractError(error) {
        if (typeof error === 'string') return error;
        if (error?.body?.message) return error.body.message;
        if (error?.message) return error.message;
        return JSON.stringify(error);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
