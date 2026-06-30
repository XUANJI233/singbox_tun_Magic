#!/usr/bin/env python3
import argparse
import os
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_DIR = ROOT / "module"
DEFAULT_ZIP_NAME = "星盘.zip"


EXECUTABLES = {
    "customize.sh",
    "service.sh",
    "post-fs-data.sh",
    "action.sh",
    "uninstall.sh",
    "common/magicctl",
    "META-INF/com/google/android/update-binary",
    "bin/arm64-v8a/sing-box",
    "bin/arm64-v8a/magic-fetch",
    "bin/x86_64/sing-box",
    "bin/x86_64/magic-fetch",
}


def read_module_prop() -> dict[str, str]:
    props: dict[str, str] = {}
    for line in (MODULE_DIR / "module.prop").read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        props[key.strip()] = value.strip()
    return props


def should_skip(path: Path) -> bool:
    rel = path.relative_to(MODULE_DIR).as_posix()
    if rel.startswith("tools/"):
        return True
    if any(part in {".git", "__pycache__"} for part in path.parts):
        return True
    return path.name.endswith((".tmp", ".bak"))


def zip_mode(rel: str) -> int:
    return 0o755 if rel in EXECUTABLES else 0o644


def add_file(zf: zipfile.ZipFile, file_path: Path, rel: str) -> None:
    info = zipfile.ZipInfo(rel)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = (zip_mode(rel) & 0xFFFF) << 16
    info.date_time = (2026, 6, 30, 0, 0, 0)
    zf.writestr(info, file_path.read_bytes())


def main() -> None:
    parser = argparse.ArgumentParser(description="Package the Magisk/KernelSU module zip.")
    parser.add_argument("--output", default=str(ROOT / "dist" / DEFAULT_ZIP_NAME))
    args = parser.parse_args()

    props = read_module_prop()
    missing = [
        "module.prop",
        "customize.sh",
        "common/magicctl",
        "bin/arm64-v8a/sing-box",
        "bin/x86_64/sing-box",
        "bin/arm64-v8a/magic-fetch",
        "bin/x86_64/magic-fetch",
        "bin/applist.dex",
    ]
    for rel in missing:
        if not (MODULE_DIR / rel).is_file():
            raise SystemExit(f"missing module file: module/{rel}")

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()

    with zipfile.ZipFile(out, "w") as zf:
        for file_path in sorted(MODULE_DIR.rglob("*")):
            if not file_path.is_file() or should_skip(file_path):
                continue
            rel = file_path.relative_to(MODULE_DIR).as_posix()
            add_file(zf, file_path, rel)

    print(f"built {out}")
    print(f"module id={props.get('id')} version={props.get('version')} versionCode={props.get('versionCode')}")


if __name__ == "__main__":
    main()
