import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "src"), str(ROOT), str(ROOT / "tests")]

# Fast password hashing in tests only.
os.environ.setdefault("LENDEN_PBKDF2_ITERS", "1000")
