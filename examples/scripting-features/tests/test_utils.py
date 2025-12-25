"""Tests for utils module."""

import sys
sys.path.insert(0, 'src')

from utils import format_string, safe_divide

def test_format_string():
    assert format_string("  hello  ") == "Hello"
    assert format_string("WORLD") == "World"
    assert format_string("  HELLO WORLD  ") == "Hello World"

def test_safe_divide():
    assert safe_divide(10, 2) == 5.0
    assert safe_divide(10, 0) == 0.0
    assert safe_divide(0, 5) == 0.0

if __name__ == "__main__":
    test_format_string()
    test_safe_divide()
    print("All utils tests passed!")

