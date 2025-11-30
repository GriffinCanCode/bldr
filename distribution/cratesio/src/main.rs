use std::env;
use std::ffi::CString;
use std::os::raw::{c_char, c_int};

extern "C" {
    fn c_run_builder(argc: c_int, argv: *const *const c_char) -> c_int;
}

fn main() {
    let args: Vec<CString> = env::args()
        .map(|arg| CString::new(arg).expect("Arg error"))
        .collect();
    
    let c_argv: Vec<*const c_char> = args.iter().map(|arg| arg.as_ptr()).collect();
    
    // c_run_builder internally handles D runtime init/term (rt_init/rt_term)
    unsafe {
        std::process::exit(c_run_builder(args.len() as c_int, c_argv.as_ptr()));
    }
}
