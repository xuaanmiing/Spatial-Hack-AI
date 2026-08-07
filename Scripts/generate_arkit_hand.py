#!/usr/bin/env python3
"""Validate and package the procedural ARKit hand USD source."""

from pathlib import Path
import shutil
import subprocess
import sys


def main() -> int:
    repository = Path(__file__).resolve().parents[1]
    resources = repository / "PhantomMirror" / "Resources"
    source = resources / "RightHand_ARKit27.usda"
    output = resources / "RightHand_ARKit27.usdz"

    if not source.is_file():
        print(f"Missing USD source: {source}", file=sys.stderr)
        return 1
    if shutil.which("xcrun") is None:
        print("xcrun is required; install Xcode command-line tools.", file=sys.stderr)
        return 1

    subprocess.run(["xcrun", "usdchecker", str(source)], check=True)
    temporary = output.with_suffix(".tmp.usdz")
    try:
        subprocess.run(
            ["xcrun", "usdzip", "--arkitAsset", str(source), str(temporary)],
            check=True,
        )
        temporary.replace(output)
        subprocess.run(["xcrun", "usdchecker", str(output)], check=True)
    finally:
        temporary.unlink(missing_ok=True)

    print(f"Generated {output.relative_to(repository)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
