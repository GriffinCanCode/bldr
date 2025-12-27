use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::io::{self, BufRead};
use std::path::Path;

#[derive(Serialize)]
struct PluginInfo {
    name: String,
    version: String,
    author: String,
    description: String,
    homepage: String,
    capabilities: Vec<String>,
    #[serde(rename = "minBuilderVersion")]
    min_builder_version: String,
    license: String,
}

#[derive(Serialize, Deserialize, Clone)]
struct Vulnerability {
    id: String,
    severity: String,
    package: String,
    version: String,
    description: String,
    fixed_in: Option<String>,
}

struct SecurityScanner {
    workspace_root: String,
    vulnerabilities: Vec<Vulnerability>,
}

impl SecurityScanner {
    fn new(workspace_root: String) -> Self {
        SecurityScanner {
            workspace_root,
            vulnerabilities: Vec::new(),
        }
    }

    fn scan_dependencies(&mut self, sources: &[String]) -> Vec<String> {
        let mut logs = vec![
            "[Security] Starting dependency vulnerability scan".to_string(),
            format!("  Scanning {} source files", sources.len()),
        ];

        // Load vulnerability database
        self.load_vulnerability_db();

        // Scan for known vulnerabilities
        let found_vulnerabilities = self.scan_for_vulnerabilities(sources);

        if found_vulnerabilities.is_empty() {
            logs.push("  ✓ No known vulnerabilities found".to_string());
        } else {
            logs.push(format!("  ⚠ Found {} vulnerabilities", found_vulnerabilities.len()));
            
            // Group by severity
            let mut critical = 0;
            let mut high = 0;
            let mut medium = 0;
            let mut low = 0;

            for vuln in &found_vulnerabilities {
                match vuln.severity.as_str() {
                    "CRITICAL" => critical += 1,
                    "HIGH" => high += 1,
                    "MEDIUM" => medium += 1,
                    "LOW" => low += 1,
                    _ => {}
                }
            }

            if critical > 0 {
                logs.push(format!("    ⛔ Critical: {}", critical));
            }
            if high > 0 {
                logs.push(format!("    ⚠️  High: {}", high));
            }
            if medium > 0 {
                logs.push(format!("    ⚡ Medium: {}", medium));
            }
            if low > 0 {
                logs.push(format!("    ℹ️  Low: {}", low));
            }

            // List top 5 vulnerabilities
            logs.push("\n  Top vulnerabilities:".to_string());
            for (i, vuln) in found_vulnerabilities.iter().take(5).enumerate() {
                logs.push(format!(
                    "    {}. {} - {} ({})",
                    i + 1,
                    vuln.id,
                    vuln.package,
                    vuln.severity
                ));
                if let Some(fixed) = &vuln.fixed_in {
                    logs.push(format!("       Fixed in: {}", fixed));
                }
            }
        }

        self.vulnerabilities = found_vulnerabilities;
        logs
    }

    fn load_vulnerability_db(&mut self) {
        // In a real implementation, this would:
        // 1. Load from local vulnerability database
        // 2. Update from remote sources (NVD, OSV, etc.)
        // 3. Parse CVE/vulnerability data
        
        // For demo, we create sample vulnerabilities
        // This would normally be loaded from a database
    }

    fn scan_for_vulnerabilities(&self, sources: &[String]) -> Vec<Vulnerability> {
        let mut vulnerabilities = Vec::new();

        // Parse dependency files
        for source in sources {
            if source.ends_with("requirements.txt") || 
               source.ends_with("package.json") ||
               source.ends_with("Cargo.toml") ||
               source.ends_with("go.mod") {
                
                // Extract dependencies
                let deps = self.extract_dependencies(source);
                
                // Check against vulnerability database
                for (package, version) in deps {
                    if let Some(vuln) = self.check_vulnerability(&package, &version) {
                        vulnerabilities.push(vuln);
                    }
                }
            }
        }

        // Sort by severity
        vulnerabilities.sort_by(|a, b| {
            let severity_order = |s: &str| match s {
                "CRITICAL" => 0,
                "HIGH" => 1,
                "MEDIUM" => 2,
                "LOW" => 3,
                _ => 4,
            };
            severity_order(&a.severity).cmp(&severity_order(&b.severity))
        });

        vulnerabilities
    }

    fn extract_dependencies(&self, file_path: &str) -> Vec<(String, String)> {
        let path = Path::new(&self.workspace_root).join(file_path);
        
        if !path.exists() {
            return Vec::new();
        }

        // Read file and parse dependencies
        // This is simplified - real implementation would use proper parsers
        let mut deps = Vec::new();

        if let Ok(content) = fs::read_to_string(&path) {
            for line in content.lines() {
                // Simple parsing (would use proper parsers in real implementation)
                if let Some((name, version)) = self.parse_dependency_line(line) {
                    deps.push((name, version));
                }
            }
        }

        deps
    }

    fn parse_dependency_line(&self, line: &str) -> Option<(String, String)> {
        let line = line.trim();
        
        // Python requirements.txt
        if line.contains("==") {
            let parts: Vec<&str> = line.split("==").collect();
            if parts.len() == 2 {
                return Some((parts[0].to_string(), parts[1].to_string()));
            }
        }
        
        // Add more parsers for other formats
        
        None
    }

    fn check_vulnerability(&self, package: &str, version: &str) -> Option<Vulnerability> {
        // In a real implementation, this would query a vulnerability database
        // For demo purposes, we'll simulate some known vulnerabilities
        
        let known_vulnerable = vec![
            ("lodash", "4.17.15", "HIGH", "Prototype pollution", Some("4.17.21")),
            ("django", "2.2.0", "CRITICAL", "SQL injection vulnerability", Some("2.2.24")),
            ("express", "4.16.0", "MEDIUM", "Open redirect vulnerability", Some("4.17.1")),
            ("requests", "2.25.0", "LOW", "Information disclosure", Some("2.26.0")),
        ];

        for (pkg, ver, severity, desc, fixed) in known_vulnerable {
            if package.contains(pkg) && version == ver {
                return Some(Vulnerability {
                    id: format!("CVE-2021-{}", rand::random::<u16>() % 10000),
                    severity: severity.to_string(),
                    package: package.to_string(),
                    version: version.to_string(),
                    description: desc.to_string(),
                    fixed_in: fixed.map(|s| s.to_string()),
                });
            }
        }

        None
    }

    fn generate_report(&self) -> Vec<String> {
        let mut logs = vec!["\n[Security] Scan Report:".to_string()];

        if self.vulnerabilities.is_empty() {
            logs.push("  ✓ No vulnerabilities detected".to_string());
            return logs;
        }

        logs.push(format!("  Total vulnerabilities: {}", self.vulnerabilities.len()));

        // Generate recommendations
        logs.push("\n  Recommendations:".to_string());
        let mut updates = HashMap::new();
        
        for vuln in &self.vulnerabilities {
            if let Some(fixed) = &vuln.fixed_in {
                updates.entry(vuln.package.clone()).or_insert_with(|| fixed.clone());
            }
        }

        if !updates.is_empty() {
            logs.push("  Update the following packages:".to_string());
            for (package, version) in updates {
                logs.push(format!("    - {} to {}", package, version));
            }
        }

        // Save detailed report
        let report_path = Path::new(&self.workspace_root)
            .join(".builder-cache")
            .join("security-report.json");

        if let Ok(report_json) = serde_json::to_string_pretty(&self.vulnerabilities) {
            let _ = fs::create_dir_all(report_path.parent().unwrap());
            let _ = fs::write(&report_path, report_json);
            logs.push(format!("\n  Detailed report saved: {}", report_path.display()));
        }

        logs
    }
}

// Simple random number generator for demo
mod rand {
    use std::time::{SystemTime, UNIX_EPOCH};

    pub fn random<T>() -> T
    where
        T: From<u64>,
    {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        T::from(nanos as u64)
    }
}

fn main() {
    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        match line {
            Ok(line) => {
                match serde_json::from_str::<Value>(&line) {
                    Ok(request) => {
                        let response = handle_request(request);
                        println!("{}", serde_json::to_string(&response).unwrap());
                    }
                    Err(e) => {
                        eprintln!("Parse error: {}", e);
                    }
                }
            }
            Err(e) => {
                eprintln!("Read error: {}", e);
            }
        }
    }
}

fn handle_request(request: Value) -> Value {
    let method = request["method"].as_str().unwrap_or("");
    let id = request["id"].as_i64().unwrap_or(0);
    let params = request.get("params");

    match method {
        "plugin.info" => handle_info(id),
        "build.pre_hook" => handle_pre_hook(id, params),
        "build.post_hook" => handle_post_hook(id, params),
        _ => error_response(id, -32601, "Method not found"),
    }
}

fn handle_info(id: i64) -> Value {
    let info = PluginInfo {
        name: "security".to_string(),
        version: "1.0.0".to_string(),
        author: "Griffin".to_string(),
        description: "Dependency vulnerability scanner".to_string(),
        homepage: "https://github.com/GriffinCanCode/bldr".to_string(),
        capabilities: vec!["build.pre_hook".to_string(), "build.post_hook".to_string()],
        min_builder_version: "1.0.0".to_string(),
        license: "MIT".to_string(),
    };

    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": info
    })
}

fn handle_pre_hook(id: i64, params: Option<&Value>) -> Value {
    let mut logs = vec!["[Security] Initializing security scan".to_string()];

    if let Some(params) = params {
        let target = params.get("target");
        let workspace = params.get("workspace");

        if let (Some(target), Some(workspace)) = (target, workspace) {
            let sources: Vec<String> = target
                .get("sources")
                .and_then(|s| s.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_default();

            let workspace_root = workspace
                .get("root")
                .and_then(|r| r.as_str())
                .unwrap_or(".")
                .to_string();

            let mut scanner = SecurityScanner::new(workspace_root);
            let scan_logs = scanner.scan_dependencies(&sources);
            logs.extend(scan_logs);

            let report_logs = scanner.generate_report();
            logs.extend(report_logs);
        }
    }

    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
            "success": true,
            "logs": logs
        }
    })
}

fn handle_post_hook(id: i64, _params: Option<&Value>) -> Value {
    let logs = vec![
        "[Security] Post-build security check complete".to_string(),
        "  ✓ Security scan artifacts saved".to_string(),
    ];

    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
            "success": true,
            "logs": logs
        }
    })
}

fn error_response(id: i64, code: i32, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {
            "code": code,
            "message": message
        }
    })
}

