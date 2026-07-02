#!/usr/bin/env python3
import argparse
import re
import sys
import urllib.request
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_DIR = ROOT / "module"

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
    "bin/arm64-v8a/magicctl-go",
    "bin/x86_64/sing-box",
    "bin/x86_64/magic-fetch",
    "bin/x86_64/magicctl-go",
}

ABI_DIRS = {"arm64-v8a", "x86_64"}
RULESETS = {
    "geosite-cn.srs": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs",
    "geoip-cn.srs": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs",
}


def common_libs_from_magicctl() -> list[str]:
    script = (MODULE_DIR / "common" / "magicctl").read_text(encoding="utf-8")
    match = re.search(r"for lib in\s+(?P<body>.*?); do", script, re.S)
    if not match:
        raise SystemExit("failed to read common/lib load list from module/common/magicctl")
    body = match.group("body").replace("\\", " ")
    libs = body.split()
    if not libs:
        raise SystemExit("empty common/lib load list in module/common/magicctl")
    duplicates = sorted({name for name in libs if libs.count(name) > 1})
    if duplicates:
        raise SystemExit(f"duplicate common/lib entries in module/common/magicctl: {', '.join(duplicates)}")
    actual = sorted(path.stem for path in (MODULE_DIR / "common" / "lib").glob("*.sh"))
    extra = sorted(set(actual) - set(libs))
    if extra:
        raise SystemExit(f"common/lib scripts not loaded by module/common/magicctl: {', '.join(extra)}")
    return libs


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


def skip_for_abi(rel: str, abi: str | None) -> bool:
    if abi is None:
        return False
    parts = rel.split("/")
    if len(parts) >= 2 and parts[0] == "bin" and parts[1] in ABI_DIRS:
        return parts[1] != abi
    return False


def zip_mode(rel: str) -> int:
    return 0o755 if rel in EXECUTABLES else 0o644


def add_file(zf: zipfile.ZipFile, file_path: Path, rel: str) -> None:
    info = zipfile.ZipInfo(rel)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = (zip_mode(rel) & 0xFFFF) << 16
    info.date_time = (2026, 6, 30, 0, 0, 0)
    zf.writestr(info, file_path.read_bytes())


def download_rulesets() -> None:
    ruleset_dir = MODULE_DIR / "defaults" / "rulesets"
    ruleset_dir.mkdir(parents=True, exist_ok=True)
    for name, url in RULESETS.items():
        target = ruleset_dir / name
        tmp = target.with_suffix(target.suffix + ".tmp")
        req = urllib.request.Request(url, headers={"User-Agent": "singbox_tun_Magic/packager"})
        try:
            with urllib.request.urlopen(req, timeout=45) as resp:
                data = resp.read()
            if not data:
                raise RuntimeError("empty response")
            tmp.write_bytes(data)
            tmp.replace(target)
            print(f"ruleset {name}: downloaded {len(data)} bytes")
        except Exception as exc:
            if tmp.exists():
                tmp.unlink()
            if target.is_file() and target.stat().st_size > 0:
                print(f"ruleset {name}: using existing bundled copy after download failed: {exc}", file=sys.stderr)
                continue
            raise SystemExit(f"failed to download rule-set {name}: {exc}") from exc


def main() -> None:
    parser = argparse.ArgumentParser(description="Package the Magisk/KernelSU module zip.")
    parser.add_argument("--abi", choices=["arm64-v8a", "x86_64"], default=None,
                        help="Only include the given ABI's binaries (smaller zip).")
    parser.add_argument("--output", default=None,
                        help="Output path. Defaults to dist/SingBox_Tun_Magic_<abi>.zip")
    args = parser.parse_args()

    props = read_module_prop()
    abi = args.abi
    download_rulesets()

    if abi:
        required_bins = [f"bin/{abi}/sing-box", f"bin/{abi}/magic-fetch", f"bin/{abi}/magicctl-go"]
        default_name = f"星盘_{abi}.zip"
    else:
        required_bins = [
            "bin/arm64-v8a/sing-box", "bin/x86_64/sing-box",
            "bin/arm64-v8a/magic-fetch", "bin/x86_64/magic-fetch",
            "bin/arm64-v8a/magicctl-go", "bin/x86_64/magicctl-go",
        ]
        default_name = "星盘.zip"

    missing = ["module.prop", "customize.sh", "common/magicctl", "bin/applist.dex"] + [
        f"common/lib/{name}.sh" for name in common_libs_from_magicctl()
    ] + required_bins
    for rel in missing:
        if not (MODULE_DIR / rel).is_file():
            raise SystemExit(f"missing module file: module/{rel}")

    out = Path(args.output) if args.output else (ROOT / "dist" / default_name)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()

    with zipfile.ZipFile(out, "w") as zf:
        for file_path in sorted(MODULE_DIR.rglob("*")):
            if not file_path.is_file() or should_skip(file_path):
                continue
            rel = file_path.relative_to(MODULE_DIR).as_posix()
            if skip_for_abi(rel, abi):
                continue
            add_file(zf, file_path, rel)

    print(f"built {out}")
    print(f"module id={props.get('id')} version={props.get('version')} versionCode={props.get('versionCode')}")


if __name__ == "__main__":
    main()

