;; Simple WebAssembly Text Format example
;; Exports an add function that adds two i32 values

(module
  ;; Import fd_write from WASI for printing
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  
  ;; Memory for storing the message
  (memory 1)
  (export "memory" (memory 0))
  
  ;; Store "Hello, WASM!\n" at memory offset 0
  (data (i32.const 0) "Hello, WASM!\n")
  
  ;; iov structure at offset 100: pointer to string, length
  (data (i32.const 100) "\00\00\00\00")  ;; pointer to string (0)
  (data (i32.const 104) "\0d\00\00\00")  ;; length of string (13)
  
  ;; Add function - adds two numbers
  (func $add (export "add") (param $a i32) (param $b i32) (result i32)
    local.get $a
    local.get $b
    i32.add
  )
  
  ;; Main/start function for WASI
  (func $_start (export "_start")
    ;; fd_write(fd=1, iovs=100, iovs_len=1, nwritten=200)
    (call $fd_write
      (i32.const 1)    ;; stdout
      (i32.const 100)  ;; iov array pointer
      (i32.const 1)    ;; iov array length
      (i32.const 200)  ;; nwritten pointer
    )
    drop
  )
)


