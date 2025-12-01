use std::env;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, exit};

const VERSION: &str = "2.0.0";

fn main() {
    let binary_path = get_or_download_binary();
    
    match binary_path {
        Some(path) => {
            let args: Vec<String> = env::args().skip(1).collect();
            let status = Command::new(&path)
                .args(&args)
                .status()
                .expect("Failed to execute bldr");
            exit(status.code().unwrap_or(1));
        }
        None => {
            eprintln!("bldr: Failed to download binary for this platform.");
            eprintln!();
            eprintln!("Install via Homebrew instead:");
            eprintln!("  brew tap GriffinCanCode/bldr && brew install bldr");
            exit(1);
        }
    }
}

fn get_or_download_binary() -> Option<PathBuf> {
    let cache_dir = dirs::cache_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("bldr")
        .join(VERSION);
    
    let binary_name = if cfg!(windows) { "bldr.exe" } else { "bldr" };
    let binary_path = cache_dir.join(binary_name);
    
    // Return cached binary if exists
    if binary_path.exists() {
        return Some(binary_path);
    }
    
    // Determine platform
    let (os, arch) = get_platform();
    let asset_name = format!("bldr-{}-{}", os, arch);
    let url = format!(
        "https://github.com/GriffinCanCode/bldr/releases/download/v{}/{}.tar.gz",
        VERSION, asset_name
    );
    
    eprintln!("Downloading bldr v{} for {}-{}...", VERSION, os, arch);
    
    // Create cache directory
    fs::create_dir_all(&cache_dir).ok()?;
    
    let archive_path = cache_dir.join("bldr.tar.gz");
    
    // Download
    let status = Command::new("curl")
        .args(["-fsSL", "-o", archive_path.to_str()?, &url])
        .status()
        .ok()?;
    
    if !status.success() {
        return None;
    }
    
    // Extract
    let status = Command::new("tar")
        .args(["-xzf", archive_path.to_str()?, "-C", cache_dir.to_str()?])
        .status()
        .ok()?;
    
    if !status.success() {
        return None;
    }
    
    // Make executable
    if binary_path.exists() {
        let mut perms = fs::metadata(&binary_path).ok()?.permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&binary_path, perms).ok()?;
    }
    
    // Cleanup archive
    fs::remove_file(&archive_path).ok();
    
    if binary_path.exists() {
        eprintln!("Done! Cached at {}", binary_path.display());
        Some(binary_path)
    } else {
        None
    }
}

fn get_platform() -> (&'static str, &'static str) {
    let os = if cfg!(target_os = "macos") {
        "darwin"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else {
        "unknown"
    };
    
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else if cfg!(target_arch = "x86_64") {
        "amd64"
    } else {
        "unknown"
    };
    
    (os, arch)
}
