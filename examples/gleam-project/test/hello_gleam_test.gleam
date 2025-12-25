import gleeunit
import gleeunit/should
import hello_gleam

pub fn main() {
  gleeunit.main()
}

pub fn greet_test() {
  hello_gleam.greet("Gleam")
  |> should.equal("Hello, Gleam!")
}

pub fn add_test() {
  hello_gleam.add(2, 3)
  |> should.equal(5)
}
