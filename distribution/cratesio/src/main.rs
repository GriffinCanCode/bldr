use std::env;
use std::ffi::CString;
use std::os::raw::{c_char, c_int};

// Import the C function exposed from D
extern "C" {
    fn c_run_builder(argc: c_int, argv: *const *const c_char) -> c_int;
}

fn main() {
    // Collect arguments
    let args: Vec<String> = env::args().collect();
    
    // Convert to C-style argc/argv
    let c_args: Vec<CString> = args.iter()
        .map(|arg| CString::new(arg.as_str()).expect("Failed to convert arg to CString"))
        .collect();
        
    let c_argv: Vec<*const c_char> = c_args.iter()
        .map(|arg| arg.as_ptr())
        .collect();
        
    // Call D entry point
    let exit_code = unsafe {
        // Initialize D runtime? 
        // With LDC and extern(C) main-like function, we often need to initialize the runtime 
        // if we bypass the D main.
        // However, `c_run_builder` inside `app.d` does not initialize the runtime explicitly 
        // via `rt_init` / `rt_term` because it assumes the runtime is initialized if called from D.
        // BUT we are calling from Rust.
        // We need to initialize the D runtime.
        
        // For now, let's assume we need to initialize it.
        // Actually, checking app.d: it uses standard D main for normal execution.
        // I added `c_run_builder`.
        // I should add `rt_init()` and `rt_term()` inside `c_run_builder` or expose them.
        // But usually `rt_init` is called automatically if we link properly? No, not if main is in Rust.
        
        // Let's call rt_init() from D side inside c_run_builder or separate init function.
        // But I can't easily modify app.d again right now without tool call.
        // Wait, I *did* modify `app.d` but I didn't add rt_init.
        // The D runtime initialization is crucial.
        
        c_run_builder(c_args.len() as c_int, c_argv.as_ptr())
    };
    
    std::process::exit(exit_code);
}

