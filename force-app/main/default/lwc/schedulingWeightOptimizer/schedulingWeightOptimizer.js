import { LightningElement, api } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import chartjs from '@salesforce/resourceUrl/chartjs';
import analyzePolicy from '@salesforce/apex/OptimizationAnalysisService.analyzePolicy';
import getSchedulingPolicies from '@salesforce/apex/OptimizationAnalysisService.getSchedulingPolicies';
import simulateForLwc from '@salesforce/apex/WeightSimulationService.simulateForLwc';
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
        const val = this.analysisResult?.aggregates?.avgScheduleRateDelta;
        return val != null ? Number(val).toFixed(1) : '0.0';
    }

    get avgUtilizationDelta() {
        const val = this.analysisResult?.aggregates?.avgUtilizationDelta;
        return val != null ? Number(val).toFixed(1) : '0.0';
    }

    get avgTravelReduction() {
        const val = this.analysisResult?.aggregates?.avgTravelEfficiency;
        return val != null ? Number(val).toFixed(1) : '0.0';
    }

    get totalRunsAnalyzed() {
        return this.analysisResult?.totalRunsAnalyzed || 0;
    }

    connectedCallback() {
        if (this.recordId) {
            this.selectedPolicyId = this.recordId;
            this.loadAnalysis();
        } else {
            this.loadPolicyOptions();
        }
    }

    async loadPolicyOptions() {
        try {
            const policies = await getSchedulingPolicies();
            this.policyOptions = policies.map(p => ({
                label: p.label,
                value: p.value
            }));
        } catch (error) {
            this.showToast('Error', 'Failed to load policies: ' + this.extractError(error), 'error');
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
            const resultJson = await simulateForLwc({
                schedulingPolicyId: this.selectedPolicyId
            });
            const simResult = JSON.parse(resultJson);
            this.processSimulationResults(simResult);
        } catch (error) {
            this.showToast('Error', 'Simulation failed: ' + this.extractError(error), 'error');
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

    processSimulationResults(simResult) {
        if (!simResult || !simResult.bestScenario) {
            this.recommendationText = '<p>No simulation results available. Ensure the policy has completed optimization runs.</p>';
            return;
        }

        const current = simResult.currentScenario;
        const best = simResult.bestScenario;
        const totalSims = simResult.totalSimulations || 0;
        const runsEvaluated = simResult.runsEvaluated || 0;

        // Build weight comparison table from best scenario vs current
        this.weightComparison = [];
        const currentMap = {};
        if (current && current.weights) {
            for (const w of current.weights) {
                currentMap[w.objectiveId] = Number(w.weight || 0);
            }
        }

        if (best.weights) {
            for (const w of best.weights) {
                const curW = currentMap[w.objectiveId] != null ? currentMap[w.objectiveId] : 0;
                const recW = Number(w.weight || 0);
                const change = recW - curW;
                this.weightComparison.push({
                    objectiveId: w.objectiveId,
                    objectiveName: w.objectiveName,
                    objectiveType: w.objectiveType,
                    currentWeight: curW,
                    recommendedWeight: recW,
                    changeDisplay: change > 0 ? '+' + change : change === 0 ? '\u2014' : '' + change,
                    changeClass: change > 0 ? 'change-positive' : change < 0 ? 'change-negative' : 'change-neutral'
                });
            }
        }

        // Build recommendation text with projected metrics
        const fmt = (v) => v != null ? Number(v).toFixed(1) : '0.0';
        const delta = (newVal, oldVal) => {
            const d = Number(newVal || 0) - Number(oldVal || 0);
            if (d > 0.05) return '<span style="color:#2e844a">+' + d.toFixed(1) + '%</span>';
            if (d < -0.05) return '<span style="color:#ea001e">' + d.toFixed(1) + '%</span>';
            return '<span style="color:#706e6b">no change</span>';
        };

        let text = '<p><strong>Simulation Complete:</strong> Tested <strong>' + totalSims + '</strong> weight configurations against <strong>' + runsEvaluated + '</strong> historical optimization runs.</p>';
        text += '<p><strong>Best Scenario: </strong>' + best.name + '</p>';

        text += '<table style="width:100%;border-collapse:collapse;margin:8px 0">';
        text += '<tr style="border-bottom:1px solid #d8d8d8"><th style="text-align:left;padding:4px">Metric</th><th style="padding:4px">Current</th><th style="padding:4px">Projected</th><th style="padding:4px">Change</th></tr>';

        const metrics = [
            { label: 'Schedule Rate', cur: current.projScheduleRate, proj: best.projScheduleRate },
            { label: 'Utilization', cur: current.projUtilization, proj: best.projUtilization },
            { label: 'Travel Reduction', cur: current.projTravel, proj: best.projTravel },
            { label: 'Overtime Reduction', cur: current.projOvertime, proj: best.projOvertime },
            { label: 'Preferred Resource', cur: current.projPreferred, proj: best.projPreferred }
        ];

        for (const m of metrics) {
            text += '<tr style="border-bottom:1px solid #eee">';
            text += '<td style="padding:4px">' + m.label + '</td>';
            text += '<td style="padding:4px;text-align:center">' + fmt(m.cur) + '%</td>';
            text += '<td style="padding:4px;text-align:center"><strong>' + fmt(m.proj) + '%</strong></td>';
            text += '<td style="padding:4px;text-align:center">' + delta(m.proj, m.cur) + '</td>';
            text += '</tr>';
        }
        text += '</table>';

        const scoreDelta = Number(best.compositeScore || 0) - Number(current.compositeScore || 0);
        if (scoreDelta > 0.05) {
            text += '<p style="margin-top:8px">Composite score improvement: <strong style="color:#2e844a">+' + scoreDelta.toFixed(1) + '</strong></p>';
        } else {
            text += '<p style="margin-top:8px">Current weights are near-optimal based on historical data.</p>';
        }

        text += '<p style="margin-top:12px;padding:8px 12px;background:#f3f2f2;border-radius:4px;font-size:12px;color:#706e6b">';
        text += '<strong>Note:</strong> Projections are model-based estimates using historical baselines and domain-knowledge impact coefficients \u2014 not actual optimizer runs. ';
        text += 'Apply the recommended weights, run a real optimization, then return here to analyze the results and refine further.</p>';

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
                        data: runs.map(r => Number(r.utilizationDelta || 0)),
                        borderColor: '#0176d3',
                        backgroundColor: 'rgba(1, 118, 211, 0.1)',
                        fill: true,
                        tension: 0.3
                    },
                    {
                        label: 'Schedule Rate Delta (%)',
                        data: runs.map(r => Number(r.scheduleRateDelta || 0)),
                        borderColor: '#2e844a',
                        backgroundColor: 'rgba(46, 132, 74, 0.1)',
                        fill: true,
                        tension: 0.3
                    },
                    {
                        label: 'Travel Efficiency (%)',
                        data: runs.map(r => Number(r.travelEfficiency || 0)),
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
        if (!canvas || !this.analysisResult?.aggregates) return;

        if (this.heatmapChartInstance) {
            this.heatmapChartInstance.destroy();
            this.heatmapChartInstance = null;
        }

        const agg = this.analysisResult.aggregates;
        const metrics = [
            { label: 'Schedule Rate', value: Number(agg.avgScheduleRateDelta || 0) },
            { label: 'Utilization', value: Number(agg.avgUtilizationDelta || 0) },
            { label: 'Travel Reduction', value: Number(agg.avgTravelEfficiency || 0) },
            { label: 'Overtime Reduction', value: Number(agg.avgOvertimeReduction || 0) },
            { label: 'Preferred Resource', value: Number(agg.avgPreferredResourceRate || 0) }
        ];

        const labels = metrics.map(m => m.label);
        const values = metrics.map(m => parseFloat(m.value.toFixed(1)));
        const bgColors = values.map(v => {
            if (v > 10) return 'rgba(46, 132, 74, 0.75)';
            if (v > 0.5) return 'rgba(1, 118, 211, 0.75)';
            return 'rgba(176, 85, 55, 0.6)';
        });
        const borderColors = values.map(v => {
            if (v > 10) return '#2e844a';
            if (v > 0.5) return '#0176d3';
            return '#b05537';
        });

        const valueLabelPlugin = {
            id: 'perfValueLabels',
            afterDatasetsDraw(chart) {
                const { ctx: c } = chart;
                chart.getDatasetMeta(0).data.forEach((bar, idx) => {
                    const v = chart.data.datasets[0].data[idx];
                    c.fillStyle = '#3e3e3c';
                    c.font = 'bold 12px -apple-system, BlinkMacSystemFont, sans-serif';
                    c.textAlign = 'left';
                    c.textBaseline = 'middle';
                    c.fillText(v.toFixed(1) + '%', bar.x + 6, bar.y);
                });
            }
        };

        this.heatmapChartInstance = new window.Chart(canvas, {
            type: 'bar',
            data: {
                labels: labels,
                datasets: [{
                    label: 'Avg Improvement (%)',
                    data: values,
                    backgroundColor: bgColors,
                    borderColor: borderColors,
                    borderWidth: 1,
                    borderRadius: 4,
                    barPercentage: 0.65
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                indexAxis: 'y',
                plugins: {
                    legend: { display: false },
                    tooltip: {
                        callbacks: {
                            label: (tooltipCtx) => {
                                const v = tooltipCtx.raw;
                                const rating = v > 10 ? 'Strong' : v > 2 ? 'Moderate' : v > 0 ? 'Minimal' : 'No improvement';
                                return rating + ': ' + v.toFixed(1) + '%';
                            }
                        }
                    }
                },
                scales: {
                    x: {
                        beginAtZero: true,
                        grid: { color: '#eee' },
                        title: { display: true, text: 'Avg Improvement (%)', font: { size: 11 } }
                    },
                    y: {
                        grid: { display: false },
                        ticks: { font: { size: 12 } }
                    }
                }
            },
            plugins: [valueLabelPlugin]
        });
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
