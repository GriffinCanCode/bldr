"""Utils module - demonstrates scripting-generated build targets."""

def format_string(s: str) -> str:
    """Format string with trimming and capitalization."""
    return s.strip().title()

def safe_divide(a: float, b: float) -> float:
    """Safely divide two numbers."""
    return a / b if b != 0 else 0.0

