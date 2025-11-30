use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    // 1. Determine source root (bundled vs repo)
    let source_root = if manifest_dir.join("dub.json").exists() {
        manifest_dir.clone()
    } else {
        manifest_dir.parent().unwrap().parent().unwrap().to_path_buf()
    };

    // 2. Setup build directory in OUT_DIR
    let build_dir = out_dir.join("build");
    if build_dir.exists() {
        std::fs::remove_dir_all(&build_dir).expect("Failed to clean build dir");
    }
    std::fs::create_dir_all(&build_dir).expect("Failed to create build dir");

    // 3. Copy source files
    copy_dir(&source_root.join("source"), &build_dir.join("source"));
    for file in ["dub.json", "Makefile"] {
        std::fs::copy(source_root.join(file), build_dir.join(file))
            .unwrap_or_else(|_| panic!("Failed to copy {}", file));
    }

    // 4. Check/Download Tools (LDC/Dub)
    let tools = ensure_tools(&out_dir);
    let path_extra = tools.as_ref().map(|t| t.bin_dir.clone());
    let (ldc_bin, dub_bin) = match tools {
        Some(t) => (t.ldc, t.dub),
        None => (PathBuf::from("ldc2"), PathBuf::from("dub")),
    };

    // 5. Build C Libraries
    run_command("make", &["build-c"], &build_dir, None);

    // 6. Build D Static Library
    let mut envs = vec![];
    if let Some(p) = &path_extra {
        if let Ok(curr) = env::var("PATH") {
            envs.push(("PATH", format!("{}:{}", p.display(), curr)));
        } else {
            envs.push(("PATH", p.to_string_lossy().to_string()));
        }
    }

    run_command(
        &dub_bin.to_string_lossy(), 
        &[
            "build".to_string(), 
            "--config=library".to_string(), 
            "--build=release".to_string(), 
            format!("--compiler={}", ldc_bin.display())
        ], 
        &build_dir,
        Some(envs)
    );

    // 7. Link Config
    println!("cargo:rustc-link-search=native={}/bin", build_dir.display());
    println!("cargo:rustc-link-lib=static=builder-core");

    // Link C Objects (archive them first)
    let obj_dir = build_dir.join("bin/obj");
    let c_lib_path = obj_dir.join("libbuilder-c.a");
    
    let obj_files: Vec<PathBuf> = std::fs::read_dir(&obj_dir)
        .expect("Failed to read obj dir")
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().map_or(false, |e| e == "o"))
        .collect();

    if !obj_files.is_empty() {
        let mut args: Vec<String> = vec!["rcs".to_string(), c_lib_path.to_string_lossy().to_string()];
        args.extend(obj_files.iter().map(|p| p.to_string_lossy().to_string()));
        
        run_command("ar", &args, &obj_dir, None);
        
        println!("cargo:rustc-link-search=native={}", obj_dir.display());
        println!("cargo:rustc-link-lib=static=builder-c");
    }

    // System Deps
    if pkg_config::Config::new().probe("tree-sitter").is_err() {
        println!("cargo:rustc-link-lib=tree-sitter");
    }

    if env::var("CARGO_CFG_TARGET_OS").unwrap() == "macos" {
        println!("cargo:rustc-link-search=native=/opt/homebrew/lib");
        println!("cargo:rustc-link-search=native=/usr/local/lib");
        println!("cargo:rustc-link-lib=c++");
    }

    println!("cargo:rustc-link-lib=phobos2-ldc");
    println!("cargo:rustc-link-lib=druntime-ldc");

    println!("cargo:rerun-if-changed={}/source", source_root.display());
    println!("cargo:rerun-if-changed={}/dub.json", source_root.display());
}

fn copy_dir(src: &Path, dst: &Path) {
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

struct Tools { ldc: PathBuf, dub: PathBuf, bin_dir: PathBuf }

fn ensure_tools(out_dir: &Path) -> Option<Tools> {
    let has_ldc = Command::new("ldc2").arg("--version").output().is_ok();
    let has_dub = Command::new("dub").arg("--version").output().is_ok();
    
    if has_ldc && has_dub { return None; }

    println!("cargo:warning=Downloading LDC/Dub...");
    let target = format!("{}-{}", env::var("CARGO_CFG_TARGET_OS").unwrap(), env::var("CARGO_CFG_TARGET_ARCH").unwrap());
    let (archive, dir_name) = match target.as_str() {
        "macos-aarch64" => ("ldc-1.35.0-osx-arm64.tar.xz", "ldc-1.35.0-osx-arm64"),
        "macos-x86_64" => ("ldc-1.35.0-osx-x86_64.tar.xz", "ldc-1.35.0-osx-x86_64"),
        "linux-x86_64" => ("ldc-1.35.0-linux-x86_64.tar.xz", "ldc-1.35.0-linux-x86_64"),
        "linux-aarch64" => ("ldc-1.35.0-linux-aarch64.tar.xz", "ldc-1.35.0-linux-aarch64"),
        _ => panic!("Unsupported platform: {}", target),
    };

    let tools_dir = out_dir.join("tools");
    let install_dir = tools_dir.join(dir_name);
    
    if !install_dir.exists() {
        std::fs::create_dir_all(&tools_dir).unwrap();
        let url = format!("https://github.com/ldc-developers/ldc/releases/download/v1.35.0/{}", archive);
        let archive_path = tools_dir.join(archive);
        
        run_command("curl", &["-L", "-o", archive_path.to_str().unwrap(), &url], &tools_dir, None);
        run_command("tar", &["-xf", archive_path.to_str().unwrap()], &tools_dir, None);
    }

    let bin_dir = install_dir.join("bin");
    println!("cargo:rustc-link-search=native={}", install_dir.join("lib").display());
    
    Some(Tools {
        ldc: bin_dir.join("ldc2"),
        dub: bin_dir.join("dub"),
        bin_dir
    })
}

fn run_command(cmd: &str, args: &[impl AsRef<str>], dir: &Path, envs: Option<Vec<(&str, String)>>) {
    let mut command = Command::new(cmd);
    command.args(args.iter().map(|s| s.as_ref())).current_dir(dir);
    if let Some(vars) = envs {
        for (k, v) in vars { command.env(k, v); }
    }
    let status = command.status().expect(&format!("Failed to run {}", cmd));
    if !status.success() { panic!("Command {} failed", cmd); }
}
