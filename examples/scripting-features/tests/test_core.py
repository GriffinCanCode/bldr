"""Tests for core module."""

import sys
sys.path.insert(0, 'src')

from core import greet, compute

def test_greet():
    assert greet("World") == "Hello, World!"
    assert greet("Builder") == "Hello, Builder!"

def test_compute():
    assert compute(2, 3) == 5
    assert compute(-1, 1) == 0
    assert compute(0, 0) == 0

if __name__ == "__main__":
    test_greet()
    test_compute()
    print("All core tests passed!")

