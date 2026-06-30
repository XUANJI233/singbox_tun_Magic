#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
from urllib.parse import quote


ROOT = Path(__file__).resolve().parents[1]
MODULE_PROP = ROOT / "module" / "module.prop"


def read_module_prop() -> dict[str, str]:
    props: dict[str, str] = {}
    for line in MODULE_PROP.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        props[key.strip()] = value.strip()
    return props


def main() -> None:
    parser = argparse.ArgumentParser(description="Write Magisk-compatible update.json.")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", "XUANJI233/singbox_tun_Magic"))
    parser.add_argument("--zip-name", default="星盘.zip")
    parser.add_argument("--out", default=str(ROOT / "dist" / "update.json"))
    args = parser.parse_args()

    props = read_module_prop()
    zip_name = quote(args.zip_name)
    release_base = f"https://github.com/{args.repository}/releases/latest"
    data = {
        "version": props["version"],
        "versionCode": int(props["versionCode"]),
        "zipUrl": f"{release_base}/download/{zip_name}",
        "changelog": release_base,
    }

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
