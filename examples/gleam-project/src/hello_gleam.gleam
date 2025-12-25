import gleam/io

pub fn main() {
  io.println("Hello from Gleam!")
  greet("World")
}

pub fn greet(name: String) -> String {
  "Hello, " <> name <> "!"
}

pub fn add(a: Int, b: Int) -> Int {
  a + b
}
