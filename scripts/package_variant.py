"""Explicit jailbreak package variants; generated inputs never mutate templates."""
from pathlib import Path
import plistlib
import shutil

VARIANTS = {
    "rootless": {"architecture": "iphoneos-arm64", "prefix": "/var/jb", "repository": "redditbox"},
    "rootful": {"architecture": "iphoneos-arm", "prefix": "", "repository": "redditbox-rootful"},
}


def variant(scheme="rootless"):
    if scheme not in VARIANTS:
        raise ValueError("RBX_PACKAGE_SCHEME must be rootless or rootful")
    return VARIANTS[scheme]


def render_script(text, scheme):
    return text.replace("/var/jb", variant(scheme)["prefix"])


def prepare(root, scheme):
    config = variant(scheme)
    output = root / "build/generated" / scheme
    output.mkdir(parents=True, exist_ok=True)
    layout = output / "layout"
    shutil.copytree(root / "layout", layout, dirs_exist_ok=True)
    for source in (root / "layout/DEBIAN").iterdir():
        if source.is_file():
            target = layout / "DEBIAN" / source.name
            target.write_text(render_script(source.read_text(encoding="utf-8"), scheme), encoding="utf-8", newline="\n")
            target.chmod(0o755)
    info = plistlib.loads((root / "daemon/com.redditbox.daemon.plist").read_bytes())
    info["Program"] = config["prefix"] + "/usr/bin/redditboxd"
    (output / "com.redditbox.daemon.plist").write_bytes(plistlib.dumps(info))
    for name in ("provision-profile.sh", "on-device-smoke.sh"):
        target = output / name
        target.write_text(render_script((root / "scripts" / name).read_text(encoding="utf-8"), scheme), encoding="utf-8", newline="\n")
        target.chmod(0o755)
    return output


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scheme", choices=VARIANTS)
    args = parser.parse_args()
    print(prepare(Path(__file__).resolve().parents[1], args.scheme))
