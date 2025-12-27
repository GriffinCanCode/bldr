;; WebAssembly library module
;; Exports utility functions for browser usage

(module
  ;; Memory (1 page = 64KB)
  (memory (export "memory") 1)
  
  ;; Add two integers
  (func (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add
  )
  
  ;; Subtract two integers
  (func (export "sub") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.sub
  )
  
  ;; Multiply two integers
  (func (export "mul") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.mul
  )
  
  ;; Factorial (iterative)
  (func (export "factorial") (param $n i32) (result i32)
    (local $result i32)
    (local $i i32)
    
    ;; result = 1
    (local.set $result (i32.const 1))
    ;; i = 1
    (local.set $i (i32.const 1))
    
    ;; while i <= n
    (block $break
      (loop $continue
        ;; if i > n, break
        (br_if $break (i32.gt_s (local.get $i) (local.get $n)))
        
        ;; result = result * i
        (local.set $result (i32.mul (local.get $result) (local.get $i)))
        
        ;; i = i + 1
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        
        ;; continue loop
        (br $continue)
      )
    )
    
    local.get $result
  )
  
  ;; Fibonacci (recursive would overflow stack, so iterative)
  (func (export "fibonacci") (param $n i32) (result i32)
    (local $a i32)
    (local $b i32)
    (local $temp i32)
    (local $i i32)
    
    ;; Handle base cases
    (if (result i32) (i32.le_s (local.get $n) (i32.const 1))
      (then (local.get $n))
      (else
        ;; a = 0, b = 1
        (local.set $a (i32.const 0))
        (local.set $b (i32.const 1))
        (local.set $i (i32.const 2))
        
        (block $break
          (loop $continue
            (br_if $break (i32.gt_s (local.get $i) (local.get $n)))
            
            ;; temp = a + b
            (local.set $temp (i32.add (local.get $a) (local.get $b)))
            ;; a = b
            (local.set $a (local.get $b))
            ;; b = temp
            (local.set $b (local.get $temp))
            
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $continue)
          )
        )
        
        local.get $b
      )
    )
  )
)


