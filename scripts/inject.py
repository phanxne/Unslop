#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Add Unslop.dylib to a decrypted Viber IPA.

usage: inject.py <decrypted.ipa> <Unslop.dylib> <out.ipa>

The output is unsigned. Re-sign it with your own certificate before installing.
"""
import os
import shutil
import sys
import tempfile
import zipfile

import lief

LOAD_PATH = "@rpath/Unslop.dylib"


def main(ipa: str, dylib: str, out: str) -> None:
    tmp = tempfile.mkdtemp()
    try:
        with zipfile.ZipFile(ipa) as z:
            z.extractall(tmp)
        payload = os.path.join(tmp, "Payload")
        app = os.path.join(payload, next(d for d in os.listdir(payload) if d.endswith(".app")))
        exe = os.path.join(app, "Viber")

        frameworks = os.path.join(app, "Frameworks")
        os.makedirs(frameworks, exist_ok=True)
        shutil.copy(dylib, os.path.join(frameworks, "Unslop.dylib"))

        fat = lief.MachO.parse(exe)
        binary = fat.at(0) if hasattr(fat, "at") else fat
        if not any("Unslop" in lib.name for lib in binary.libraries):
            binary.add_library(LOAD_PATH)
        binary.write(exe)

        shutil.rmtree(os.path.join(app, "_CodeSignature"), ignore_errors=True)
        if os.path.exists(out):
            os.remove(out)
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            for root, _, files in os.walk(payload):
                for f in files:
                    p = os.path.join(root, f)
                    z.write(p, os.path.relpath(p, tmp))
        print("wrote", out)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
