"""Point FluidAudio's NemoTextProcessing binaryTarget at a local xcframework.

Usage: patch_fluidaudio.py MANIFEST LOCAL_PATH   (idempotent)
"""
import re
import sys

manifest, local = sys.argv[1], sys.argv[2]
text = open(manifest).read()
new, n = re.subn(r'url:\s*"[^"]*NemoTextProcessing\.xcframework\.zip",\s*checksum:\s*"[0-9a-f]+"',
                 f'path: "{local}"', text)
if n == 0 and f'path: "{local}"' not in text:
    sys.exit(f"✗ {manifest}: NemoTextProcessing binaryTarget not found")
open(manifest, "w").write(new)
