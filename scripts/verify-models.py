#!/usr/bin/env python3
"""Checks catalog/models.json against Hugging Face.

For every model: the repo exists and is public (not gated), it contains a
~4-bit GGUF (Q4_K_M preferred), and the listed sizeGB is within 20% of that
file's real size (split files are summed). Entries marked "mtp": true must
have MTP tensors in that file's header (first 16 MB, fetched with a Range
request). Prints a table; exits 1 on any failure. Uses only the standard
library. HF_TOKEN is optional.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

CATALOG = sys.argv[1] if len(sys.argv) > 1 else "catalog/models.json"
PREFERRED = ["Q4_K_M", "UD-Q4_K_XL", "Q4_K_XL", "MXFP4", "Q4_0", "Q4_K_S", "IQ4_XS", "Q4_1"]
TOLERANCE = 0.20
SPLIT = re.compile(r"-(\d{5})-of-(\d{5})\.gguf$")


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "llamamate-catalog-check"})
    token = os.environ.get("HF_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode()), r.headers


def header_has_mtp(repo, path):
    """True if the GGUF header (first 16 MB) names MTP (nextn) tensors."""
    url = f"https://huggingface.co/{repo}/resolve/main/{urllib.parse.quote(path)}"
    req = urllib.request.Request(url, headers={"User-Agent": "llamamate-catalog-check",
                                               "Range": "bytes=0-16777215"})
    token = os.environ.get("HF_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=120) as r:
        head = r.read(16 * 1024 * 1024)
    return b"nextn_predict_layers" in head and b".nextn." in head


def list_files(repo):
    files = []
    url = f"https://huggingface.co/api/models/{repo}/tree/main?recursive=true"
    while url:
        data, headers = get(url)
        for e in data:
            if e.get("type") == "file" and e.get("path", "").endswith(".gguf"):
                size = (e.get("lfs") or {}).get("size") or e.get("size") or 0
                files.append((e["path"], size))
        m = re.search(r'<([^>]+)>;\s*rel="next"', headers.get("Link", "") or "")
        url = m.group(1) if m else None
    return files


def pick(files):
    """Best ~4-bit GGUF; split sets are grouped and summed."""
    groups = {}
    for path, size in files:
        name = path.split("/")[-1]
        if "mmproj" in name.lower():
            continue
        key = SPLIT.sub("", path)
        g = groups.setdefault(key, [0, path])
        g[0] += size
    for quant in PREFERRED:
        for key, (size, first) in sorted(groups.items()):
            if quant.lower() in key.lower():
                return quant, first, size
    return None


def main():
    with open(CATALOG) as f:
        catalog = json.load(f)
    assert catalog.get("version") == 1, "unsupported catalog version"
    # "models" is the main shortlist; "community" holds opt-in fine-tunes
    # (separate key, so app versions without the opt-in never show them).
    models = [dict(m, _list="models") for m in catalog["models"]]
    models += [dict(m, _list="community") for m in catalog.get("community", [])]
    ids = [m["id"] for m in models]
    failures = 0
    rows = []
    if len(ids) != len(set(ids)):
        print("FAIL duplicate ids in catalog")
        failures += 1
    for m in models:
        for key in ("id", "name", "sizeGB", "minRAM", "description"):
            if key not in m:
                rows.append((m.get("id", "?"), "FAIL", f"missing '{key}'"))
                failures += 1
        repo = m["id"] if m["_list"] == "models" else m["id"] + "  [community]"
        if "id" not in m:
            continue
        try:
            info, _ = get(f"https://huggingface.co/api/models/{m['id']}")
            if info.get("gated"):
                rows.append((repo, "FAIL", f"gated ({info.get('gated')}) - needs a login"))
                failures += 1
                continue
            found = pick(list_files(m["id"]))
        except urllib.error.HTTPError as e:
            rows.append((repo, "FAIL", f"HTTP {e.code}"))
            failures += 1
            continue
        except Exception as e:  # network etc.
            rows.append((repo, "FAIL", str(e)))
            failures += 1
            continue
        if not found:
            rows.append((repo, "FAIL", "no ~4-bit GGUF file"))
            failures += 1
            continue
        quant, path, size = found
        real = size / 1e9
        listed = float(m["sizeGB"])
        if real <= 0 or abs(listed - real) / real > TOLERANCE:
            rows.append((repo, "FAIL", f"sizeGB {listed} but {quant} is {real:.1f} GB ({path})"))
            failures += 1
        elif m.get("mtp") and not header_has_mtp(m["id"], path):
            rows.append((repo, "FAIL", f"marked mtp but {path} has no MTP (nextn) tensors"))
            failures += 1
        else:
            note = " + MTP heads" if m.get("mtp") else ""
            rows.append((repo, "ok", f"{quant} {real:.1f} GB ({path}){note}"))

    width = max(len(r[0]) for r in rows) if rows else 10
    lines = [f"{s:4}  {repo:{width}}  {detail}" for repo, s, detail in rows]
    print("\n".join(lines))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write("| Model | Result | Detail |\n|---|---|---|\n")
            for repo, s, detail in rows:
                f.write(f"| `{repo}` | {s} | {detail} |\n")
    print(f"\n{len(models)} models, {failures} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
