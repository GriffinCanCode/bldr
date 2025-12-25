#!/usr/bin/env python3
"""Main application - demonstrates scripting-generated build targets."""

import os
from core import greet, compute
from utils import format_string, safe_divide

def main():
    version = os.environ.get("VERSION", "unknown")
    platform = os.environ.get("PLATFORM", "unknown")
    
    print(f"App v{version} running on {platform}")
    print(greet("Builder"))
    print(f"2 + 3 = {compute(2, 3)}")
    print(format_string("  hello world  "))
    print(f"10 / 3 = {safe_divide(10, 3):.2f}")

if __name__ == "__main__":
    main()

