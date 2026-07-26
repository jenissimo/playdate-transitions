#!/usr/bin/env python3
"""Build the demo .pdx.

The library modules live at the repo ROOT so that a consumer can add this repo
as a submodule straight inside their Source/ and `import "juice/sfxkit"`. pdc,
though, only compiles what is under the source folder it is given -- and
`import "../sfxkit"` does not resolve outside it. So the demo build copies the
modules in, compiles, and cleans up. The copies are gitignored.
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEMO = os.path.join(ROOT, "demo", "Source")
OUT = os.path.join(ROOT, "demo", "Juice.pdx")

MODULES = [
    "transitions.lua", "sfxkit.lua", "jukebox.lua",
    "tween.lua", "shake.lua", "particles.lua", "backgrounds.lua",
]


def find_pdc():
    sdk = os.environ.get("PLAYDATE_SDK_PATH")
    candidates = []
    if sdk:
        candidates += [os.path.join(sdk, "bin", "pdc.exe"),
                       os.path.join(sdk, "bin", "pdc")]
    candidates += [
        os.path.expanduser("~/Documents/PlaydateSDK/bin/pdc.exe"),
        os.path.expanduser("~/Developer/PlaydateSDK/bin/pdc"),
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    found = shutil.which("pdc")
    if found:
        return found
    sys.exit("pdc not found -- set PLAYDATE_SDK_PATH")


def main():
    copied = []
    try:
        for m in MODULES:
            src = os.path.join(ROOT, m)
            if not os.path.isfile(src):
                sys.exit("missing module: " + m)
            dst = os.path.join(DEMO, m)
            shutil.copy2(src, dst)
            copied.append(dst)

        # The paw effect loads images/ from the pdx root by the same relative
        # path the library uses, so the folder has to come along too.
        img_src = os.path.join(ROOT, "images")
        img_dst = os.path.join(DEMO, "images")
        if os.path.isdir(img_src):
            shutil.copytree(img_src, img_dst, dirs_exist_ok=True)

        pdc = find_pdc()
        print("pdc:", pdc)
        r = subprocess.run([pdc, DEMO, OUT])
        if r.returncode != 0:
            sys.exit(r.returncode)
        print("built", OUT)
    finally:
        for c in copied:
            if os.path.isfile(c):
                os.remove(c)
        img_dst = os.path.join(DEMO, "images")
        if os.path.isdir(img_dst):
            shutil.rmtree(img_dst, ignore_errors=True)


if __name__ == "__main__":
    main()
