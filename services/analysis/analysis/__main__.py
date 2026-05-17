"""Entry point so the package can be invoked as `python -m analysis`."""

import sys
from .cli import main

if __name__ == "__main__":
    sys.exit(main())
