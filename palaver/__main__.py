"""Entry point for `python -m palaver` and the console script."""

from .cli import main
from .install_layout import clean_environment

clean_environment()

if __name__ == "__main__":
    raise SystemExit(main())
