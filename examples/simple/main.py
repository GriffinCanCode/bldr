"""Main application entry point."""
import sys
import os

def main():
    """Run the main application."""
    from utils import greet, add, process_data, FileHandler
    
    print(greet("Builder"))
    print(f"2 + 3 = {add(2, 3)}")
    
    # Test data processing (80/20 rule: common use cases)
    data = [1, 2, 3, 4, 5]
    result = process_data(data)
    print(f"Processed data: {result}")
    
    # Test file handling
    handler = FileHandler()
    print(f"Working directory: {handler.get_cwd()}")
    
    # Test command line arguments
    if len(sys.argv) > 1:
        print(f"Arguments: {sys.argv[1:]}")

if __name__ == "__main__":
    main()
