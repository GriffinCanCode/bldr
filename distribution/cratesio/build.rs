use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let manifest_path = PathBuf::from(&manifest_dir);
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    // Determine root directory (handle both repo layout and packaged crate layout)
    let source_root = if manifest_path.join("dub.json").exists() {
        manifest_path.clone() // We are in a bundled crate
    } else {
        manifest_path.parent().unwrap().parent().unwrap().to_path_buf() // We are in the repo
    };
    
    // Copy source files to OUT_DIR to avoid modifying the source tree
    let build_dir = out_dir.join("build");
    if build_dir.exists() {
        std::fs::remove_dir_all(&build_dir).expect("Failed to clean build dir");
    }
    std::fs::create_dir_all(&build_dir).expect("Failed to create build dir");
    
    // Helper to copy dir recursively
    fn copy_dir(src: &PathBuf, dst: &PathBuf) {
        if !dst.exists() {
            std::fs::create_dir_all(dst).expect("Failed to create dst dir");
        }
        for entry in walkdir::WalkDir::new(src) {
            let entry = entry.expect("Failed to read entry");
            let rel_path = entry.path().strip_prefix(src).unwrap();
            let dst_path = dst.join(rel_path);
            if entry.file_type().is_dir() {
                std::fs::create_dir_all(&dst_path).ok();
            } else {
                std::fs::copy(entry.path(), &dst_path).ok();
            }
        }
    }
    
    // Copy everything needed
    copy_dir(&source_root.join("source"), &build_dir.join("source"));
    std::fs::copy(source_root.join("dub.json"), build_dir.join("dub.json")).expect("Failed to copy dub.json");
    std::fs::copy(source_root.join("Makefile"), build_dir.join("Makefile")).expect("Failed to copy Makefile");
    
    // Use build_dir as the new root for building
    let root_dir = build_dir;

    // --- Auto-install LDC/Dub if missing ---
    let ldc_version = "1.35.0"; // Pin a stable version
    
    // Check if tools exist in system path
    let has_ldc = Command::new("ldc2").arg("--version").output().is_ok();
    let has_dub = Command::new("dub").arg("--version").output().is_ok();
    
    let mut ldc_bin = PathBuf::from("ldc2");
    let mut dub_bin = PathBuf::from("dub");
    let mut path_extra = Vec::new();
    
    if !has_ldc || !has_dub {
        println!("cargo:warning=LDC/Dub not found in PATH. Attempting to download...");
        
        // Define platform-specific URL
        let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap();
        let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap();
        
        let (archive_name, dir_name) = match (target_os.as_str(), target_arch.as_str()) {
            ("macos", "aarch64") => ("ldc-1.35.0-osx-arm64.tar.xz", "ldc-1.35.0-osx-arm64"),
            ("macos", "x86_64") => ("ldc-1.35.0-osx-x86_64.tar.xz", "ldc-1.35.0-osx-x86_64"),
            ("linux", "x86_64") => ("ldc-1.35.0-linux-x86_64.tar.xz", "ldc-1.35.0-linux-x86_64"),
            ("linux", "aarch64") => ("ldc-1.35.0-linux-aarch64.tar.xz", "ldc-1.35.0-linux-aarch64"),
            // Windows support would require .7z or .zip handling and different URL logic
            _ => panic!("Unsupported platform for auto-download: {}-{}. Please install LDC manually.", target_os, target_arch),
        };
        
        let download_url = format!("https://github.com/ldc-developers/ldc/releases/download/v{}/{}", ldc_version, archive_name);
        let tools_dir = out_dir.join("tools");
        let ldc_install_dir = tools_dir.join(dir_name);
        
        if !ldc_install_dir.exists() {
            std::fs::create_dir_all(&tools_dir).expect("Failed to create tools dir");
            
            println!("cargo:warning=Downloading LDC from {}...", download_url);
            
            // Download using curl
            let archive_path = tools_dir.join(&archive_name);
            let status = Command::new("curl")
                .arg("-L") // Follow redirects
                .arg("-o")
                .arg(&archive_path)
                .arg(&download_url)
                .status()
                .expect("Failed to run curl");
                
            if !status.success() {
                panic!("Failed to download LDC");
            }
            
            println!("cargo:warning=Extracting LDC...");
            let status = Command::new("tar")
                .arg("-xf")
                .arg(&archive_path)
                .current_dir(&tools_dir)
                .status()
                .expect("Failed to run tar");
                
            if !status.success() {
                panic!("Failed to extract LDC archive");
            }
        }
        
        // Update paths
        let bin_dir = ldc_install_dir.join("bin");
        ldc_bin = bin_dir.join("ldc2");
        dub_bin = bin_dir.join("dub");
        
        if !ldc_bin.exists() {
            panic!("LDC binary not found at expected path: {}", ldc_bin.display());
        }
        
        // Add to library search path for D runtime libraries
        let lib_dir = ldc_install_dir.join("lib");
        println!("cargo:rustc-link-search=native={}", lib_dir.display());
        
        // We need to pass this bin_dir to sub-processes so dub can find ldc2
        path_extra.push(bin_dir);
    }

    // Build C libraries using Makefile
    // We use the existing Makefile to ensure consistency
    let status = Command::new("make")
        .arg("build-c")
        .current_dir(&root_dir)
        .status()
        .expect("Failed to run make build-c");

    if !status.success() {
        panic!("Failed to build C libraries");
    }

    // Build D static library
    let mut dub_cmd = Command::new(&dub_bin);
    dub_cmd.args(&["build", "--config=library", "--build=release"]);
    
    // Specify compiler explicitly
    dub_cmd.arg(format!("--compiler={}", ldc_bin.display()));
    
    // Add LDC bin to PATH so dub can find related tools if needed
    if !path_extra.is_empty() {
        let new_path = env::join_paths(&path_extra).unwrap();
        if let Ok(current_path) = env::var("PATH") {
             let p = format!("{}:{}", new_path.to_string_lossy(), current_path);
             dub_cmd.env("PATH", p);
        } else {
            dub_cmd.env("PATH", new_path);
        }
    }
    
    let status = dub_cmd
        .current_dir(&root_dir)
        .status()
        .expect("Failed to run dub build");

    if !status.success() {
        panic!("Failed to build D library");
    }

    // Link configuration
    println!("cargo:rustc-link-search=native={}/bin", root_dir.display());
    println!("cargo:rustc-link-lib=static=builder-core");

    // Link C objects
    // The Makefile puts objects in bin/obj
    let obj_dir = root_dir.join("bin").join("obj");
    
    // Link BLAKE3 and SIMD objects
    println!("cargo:rustc-link-search=native={}", obj_dir.display());
    
    // We need to link specific objects or rely on the static lib if we bundled them.
    // The D static lib usually only contains the D code.
    // We need to link the C objects manually or create a static lib for them.
    // The Makefile creates some .o files. We can bundle them into a .a or link them directly.
    // Rust doesn't support linking .o files directly easily via cargo:rustc-link-lib without a crate wrapper.
    // However, we can use `cc` crate to build a static lib from them or just instruct the linker.
    
    // Let's create a static library for the C objects using `ar` if it doesn't exist, 
    // but wait, we can just tell `cc` to compile them? 
    // Better yet, we can use the object files directly if we pass them to the linker.
    // But a cleaner way is to make `make` produce a `libbuilder-c.a`.
    
    // Let's look at what Makefile does.
    // It copies *.o to bin/obj/.
    
    // We can gather all .o files in bin/obj and archive them into libbuilder-c.a
    let c_lib_path = obj_dir.join("libbuilder-c.a");
    let mut ar_cmd = Command::new("ar");
    ar_cmd.arg("rcs").arg(&c_lib_path);
    
    for entry in std::fs::read_dir(&obj_dir).expect("Failed to read obj dir") {
        let entry = entry.expect("Error reading entry");
        let path = entry.path();
        if path.extension().map_or(false, |e| e == "o") {
            ar_cmd.arg(path);
        }
    }
    
    let status = ar_cmd.status().expect("Failed to run ar");
    if !status.success() {
        panic!("Failed to create C static library");
    }
    
    println!("cargo:rustc-link-search=native={}", obj_dir.display());
    println!("cargo:rustc-link-lib=static=builder-c"); // links libbuilder-c.a
    
    // Link system dependencies
    // tree-sitter
    if let Err(_) = pkg_config::Config::new().probe("tree-sitter") {
        // If pkg-config fails, try to guess or panic
        println!("cargo:rustc-link-lib=tree-sitter");
    }
    
    // MacOS specifics
    if env::var("CARGO_CFG_TARGET_OS").unwrap() == "macos" {
        println!("cargo:rustc-link-search=native=/opt/homebrew/lib");
        println!("cargo:rustc-link-search=native=/usr/local/lib");
        println!("cargo:rustc-link-lib=c++"); // D runtime often needs C++ stdlib if interacting with C++
    }
    
    // Link D runtime
    // LDC uses libdruntime-ldc.a and libphobos2-ldc.a
    // We generally let the linker find them, but sometimes we need explicit flags.
    // For a mixed D/Rust binary, it's safer to let a C compiler drive the link or pass explicit libs.
    // Since we are using `cargo build`, we are using `cc` (linker).
    // We might need to link `phobos2-ldc` and `druntime-ldc`.
    println!("cargo:rustc-link-lib=phobos2-ldc");
    println!("cargo:rustc-link-lib=druntime-ldc");
    
    // Force linking of curl if we used it? No, that was build-time only.
    
    // Re-run if sources change
    println!("cargo:rerun-if-changed={}/source", source_root.display());
    println!("cargo:rerun-if-changed={}/dub.json", source_root.display());
    println!("cargo:rerun-if-changed={}/Makefile", source_root.display());
}

