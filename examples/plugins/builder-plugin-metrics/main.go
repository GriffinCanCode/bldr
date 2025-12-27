package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// PluginInfo contains metadata about the plugin
type PluginInfo struct {
	Name              string   `json:"name"`
	Version           string   `json:"version"`
	Author            string   `json:"author"`
	Description       string   `json:"description"`
	Homepage          string   `json:"homepage"`
	Capabilities      []string `json:"capabilities"`
	MinBuilderVersion string   `json:"minBuilderVersion"`
	License           string   `json:"license"`
}

// BuildMetrics contains detailed build metrics
type BuildMetrics struct {
	TargetName     string        `json:"targetName"`
	StartTime      time.Time     `json:"startTime"`
	EndTime        time.Time     `json:"endTime"`
	Duration       time.Duration `json:"duration"`
	Success        bool          `json:"success"`
	SourceCount    int           `json:"sourceCount"`
	OutputCount    int           `json:"outputCount"`
	CacheHitRate   float64       `json:"cacheHitRate"`
	Parallelism    int           `json:"parallelism"`
	MemoryUsageMB  float64       `json:"memoryUsageMB"`
	CPUUtilization float64       `json:"cpuUtilization"`
}

// MetricsAggregator handles build metrics collection and analysis
type MetricsAggregator struct {
	metricsDir string
	metrics    []BuildMetrics
}

// NewMetricsAggregator creates a new metrics aggregator
func NewMetricsAggregator(workspaceRoot string) *MetricsAggregator {
	metricsDir := filepath.Join(workspaceRoot, ".builder-cache", "metrics")
	os.MkdirAll(metricsDir, 0755)

	return &MetricsAggregator{
		metricsDir: metricsDir,
		metrics:    make([]BuildMetrics, 0),
	}
}

// RecordBuildStart records the start of a build
func (m *MetricsAggregator) RecordBuildStart(targetName string, sourceCount int) {
	metric := BuildMetrics{
		TargetName:  targetName,
		StartTime:   time.Now(),
		SourceCount: sourceCount,
	}
	m.metrics = append(m.metrics, metric)
}

// RecordBuildEnd records the end of a build
func (m *MetricsAggregator) RecordBuildEnd(targetName string, success bool, outputs []string, durationMs int64) []string {
	logs := []string{
		"[Metrics] Recording build metrics",
		fmt.Sprintf("  Target: %s", targetName),
		fmt.Sprintf("  Duration: %dms", durationMs),
		fmt.Sprintf("  Success: %v", success),
		fmt.Sprintf("  Outputs: %d", len(outputs)),
	}

	// Find the corresponding start metric
	for i := range m.metrics {
		if m.metrics[i].TargetName == targetName {
			m.metrics[i].EndTime = time.Now()
			m.metrics[i].Duration = time.Duration(durationMs) * time.Millisecond
			m.metrics[i].Success = success
			m.metrics[i].OutputCount = len(outputs)

			// Calculate statistics
			m.calculateStatistics(&m.metrics[i])

			// Save metric
			if err := m.saveMetric(m.metrics[i]); err != nil {
				logs = append(logs, fmt.Sprintf("  ⚠ Failed to save metric: %v", err))
			} else {
				logs = append(logs, "  ✓ Metrics saved")
			}

			break
		}
	}

	// Generate insights
	insights := m.generateInsights()
	logs = append(logs, insights...)

	return logs
}

// calculateStatistics calculates additional statistics for a build
func (m *MetricsAggregator) calculateStatistics(metric *BuildMetrics) {
	// Simulate calculating statistics
	// In a real implementation, this would gather actual system metrics

	metric.CacheHitRate = 0.75   // 75% cache hit rate (simulated)
	metric.ParallelMeta := 4     // 4 parallel jobs (simulated)
	metric.MemoryUsageMB = 512.5 // 512.5 MB memory (simulated)
	metric.CPUUtilization = 68.3 // 68.3% CPU (simulated)
}

// saveMetric saves a metric to disk
func (m *MetricsAggregator) saveMetric(metric BuildMetrics) error {
	timestamp := metric.StartTime.Format("2006-01-02-15-04-05")
	filename := fmt.Sprintf("%s-%s.json", metric.TargetName, timestamp)
	filepath := filepath.Join(m.metricsDir, filename)

	data, err := json.MarshalIndent(metric, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(filepath, data, 0644)
}

// loadMetrics loads all saved metrics
func (m *MetricsAggregator) loadMetrics() error {
	files, err := filepath.Glob(filepath.Join(m.metricsDir, "*.json"))
	if err != nil {
		return err
	}

	m.metrics = make([]BuildMetrics, 0)

	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			continue
		}

		var metric BuildMetrics
		if err := json.Unmarshal(data, &metric); err != nil {
			continue
		}

		m.metrics = append(m.metrics, metric)
	}

	return nil
}

// generateInsights generates insights from collected metrics
func (m *MetricsAggregator) generateInsights() []string {
	if err := m.loadMetrics(); err != nil {
		return []string{"  ⚠ Failed to load historical metrics"}
	}

	if len(m.metrics) < 2 {
		return []string{"  ℹ Not enough historical data for insights"}
	}

	insights := []string{"\n[Metrics] Build Insights:"}

	// Sort by time
	sort.Slice(m.metrics, func(i, j int) bool {
		return m.metrics[i].StartTime.Before(m.metrics[j].StartTime)
	})

	// Calculate average build time
	var totalDuration time.Duration
	successCount := 0
	for _, m := range m.metrics {
		totalDuration += m.Duration
		if m.Success {
			successCount++
		}
	}
	avgDuration := totalDuration / time.Duration(len(m.metrics))
	successRate := float64(successCount) / float64(len(m.metrics)) * 100

	insights = append(insights, fmt.Sprintf("  Average build time: %v", avgDuration))
	insights = append(insights, fmt.Sprintf("  Success rate: %.1f%%", successRate))
	insights = append(insights, fmt.Sprintf("  Total builds tracked: %d", len(m.metrics)))

	// Trend analysis
	if len(m.metrics) >= 5 {
		recentMetrics := m.metrics[len(m.metrics)-5:]
		var recentDuration time.Duration
		for _, m := range recentMetrics {
			recentDuration += m.Duration
		}
		recentAvg := recentDuration / time.Duration(len(recentMetrics))

		if recentAvg < avgDuration {
			improvement := float64(avgDuration-recentAvg) / float64(avgDuration) * 100
			insights = append(insights, fmt.Sprintf("  ✓ Builds are %.1f%% faster recently", improvement))
		} else if recentAvg > avgDuration {
			regression := float64(recentAvg-avgDuration) / float64(avgDuration) * 100
			insights = append(insights, fmt.Sprintf("  ⚠ Builds are %.1f%% slower recently", regression))
		}
	}

	// Cache efficiency
	if len(m.metrics) > 0 {
		lastMetric := m.metrics[len(m.metrics)-1]
		if lastMetric.CacheHitRate > 0 {
			insights = append(insights, fmt.Sprintf("  Cache hit rate: %.1f%%", lastMetric.CacheHitRate*100))
		}
	}

	return insights
}

var pluginInfo = PluginInfo{
	Name:              "metrics",
	Version:           "1.0.0",
	Author:            "Griffin",
	Description:       "Advanced build metrics and analytics",
	Homepage:          "https://github.com/GriffinCanCode/bldr",
	Capabilities:      []string{"build.pre_hook", "build.post_hook"},
	MinBuilderVersion: "1.0.0",
	License:           "MIT",
}

func main() {
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := scanner.Text()

		var request map[string]interface{}
		if err := json.Unmarshal([]byte(line), &request); err != nil {
			writeError(-32700, "Parse error: "+err.Error())
			continue
		}

		response := handleRequest(request)
		responseJSON, _ := json.Marshal(response)
		fmt.Println(string(responseJSON))
	}
}

func handleRequest(request map[string]interface{}) map[string]interface{} {
	method, _ := request["method"].(string)
	id := int64(request["id"].(float64))
	params, _ := request["params"].(map[string]interface{})

	switch method {
	case "plugin.info":
		return handleInfo(id)
	case "build.pre_hook":
		return handlePreHook(id, params)
	case "build.post_hook":
		return handlePostHook(id, params)
	default:
		return errorResponse(id, -32601, "Method not found: "+method)
	}
}

func handleInfo(id int64) map[string]interface{} {
	return successResponse(id, pluginInfo)
}

func handlePreHook(id int64, params map[string]interface{}) map[string]interface{} {
	logs := []string{"[Metrics] Initializing build metrics collection"}

	target, _ := params["target"].(map[string]interface{})
	workspace, _ := params["workspace"].(map[string]interface{})

	targetName, _ := target["name"].(string)
	workspaceRoot, _ := workspace["root"].(string)

	logs = append(logs, fmt.Sprintf("  Target: %s", targetName))

	// Initialize metrics aggregator
	aggregator := NewMetricsAggregator(workspaceRoot)

	// Record build start
	sources, _ := target["sources"].([]interface{})
	aggregator.RecordBuildStart(targetName, len(sources))

	logs = append(logs, "  ✓ Metrics collection started")

	return successResponse(id, map[string]interface{}{
		"success": true,
		"logs":    logs,
	})
}

func handlePostHook(id int64, params map[string]interface{}) map[string]interface{} {
	target, _ := params["target"].(map[string]interface{})
	workspace, _ := params["workspace"].(map[string]interface{})
	outputs, _ := params["outputs"].([]interface{})
	success, _ := params["success"].(bool)
	durationMs := int64(params["duration_ms"].(float64))

	targetName, _ := target["name"].(string)
	workspaceRoot, _ := workspace["root"].(string)

	// Convert outputs to string slice
	outputStrs := make([]string, len(outputs))
	for i, o := range outputs {
		outputStrs[i], _ = o.(string)
	}

	// Record build end and generate insights
	aggregator := NewMetricsAggregator(workspaceRoot)
	logs := aggregator.RecordBuildEnd(targetName, success, outputStrs, durationMs)

	return successResponse(id, map[string]interface{}{
		"success": true,
		"logs":    logs,
	})
}

func successResponse(id int64, result interface{}) map[string]interface{} {
	return map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      id,
		"result":  result,
	}
}

func errorResponse(id int64, code int, message string) map[string]interface{} {
	return map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      id,
		"error": map[string]interface{}{
			"code":    code,
			"message": message,
		},
	}
}

func writeError(code int, message string) {
	response := errorResponse(0, code, message)
	responseJSON, _ := json.Marshal(response)
	fmt.Fprintln(os.Stderr, string(responseJSON))
}
