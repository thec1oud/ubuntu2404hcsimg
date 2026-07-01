#!/usr/bin/env python3
"""
generate_audit_bundle.py — Aggregate per-SKU metadata into a JSON audit bundle.

Usage:
    python3 generate_audit_bundle.py <bundle-output-dir>

Reads artefacts from:
    audit-work/prepare/          gpg-verify.log, build-environment.txt, image.sha256 ...
    audit-work/metadata/metadata-{sku}/  *.manifest.json, *-sbom.tsv, *-checksums.sha256
    audit-work/logs/logs-{sku}/          serial.log, packer.log

Reads pipeline context from environment variables (set automatically by GitHub Actions):
    BASE_SHA, GIT_SHA, BUILD_TS     from job outputs
    GITHUB_RUN_ID, GITHUB_RUN_NUMBER, GITHUB_WORKFLOW, GITHUB_ACTOR,
    GITHUB_REF, GITHUB_SHA, GITHUB_REPOSITORY, GITHUB_EVENT_NAME, GITHUB_SERVER_URL

Writes:
    <bundle-output-dir>/audit-bundle.json   (validated with a round-trip JSON parse)
"""
import json
import os
import glob
import hashlib
import datetime
import re
import sys


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def read_text(path: str) -> str | None:
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def read_json(path: str) -> dict | None:
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def parse_checksums(path: str) -> dict[str, str]:
    """Return {filename: sha256} from a sha256sum output file."""
    out: dict[str, str] = {}
    txt = read_text(path)
    if not txt:
        return out
    for line in txt.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            out[parts[1].strip()] = parts[0].strip()
    return out


def sbom_package_count(path: str) -> int | None:
    txt = read_text(path)
    if not txt:
        return None
    lines = txt.splitlines()
    return max(0, len(lines) - 1)  # subtract header row


_FAIL_CODES = re.compile(
    r"\[GNUPG:\] (BADSIG|NO_PUBKEY|ERRSIG|EXPKEYSIG|REVKEYSIG|KEYEXPIRED)"
)


def _gpg_verified(log_path: str) -> bool:
    """Return True only if the gpg-verify.log contains a GOODSIG status line
    and no failure status codes."""
    txt = read_text(log_path) or ""
    if not txt:
        return False
    has_good = "[GNUPG:] GOODSIG" in txt
    has_fail = bool(_FAIL_CODES.search(txt))
    return has_good and not has_fail


def main() -> None:
    if len(sys.argv) < 2:
        print("usage: generate_audit_bundle.py <bundle-output-dir>", file=sys.stderr)
        sys.exit(1)

    bundle_dir = sys.argv[1]
    os.makedirs(bundle_dir, exist_ok=True)

    def env(key: str, default: str = "") -> str:
        return os.environ.get(key, default)

    base_sha   = env("BASE_SHA")
    git_sha    = env("GIT_SHA")
    build_ts   = env("BUILD_TS")
    run_id     = env("GITHUB_RUN_ID")
    run_number = env("GITHUB_RUN_NUMBER")
    workflow   = env("GITHUB_WORKFLOW")
    actor      = env("GITHUB_ACTOR")
    ref        = env("GITHUB_REF")
    full_sha   = env("GITHUB_SHA")
    repo       = env("GITHUB_REPOSITORY")
    event_name = env("GITHUB_EVENT_NAME")
    server_url = env("GITHUB_SERVER_URL")
    now        = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

    skus: dict[str, dict] = {}
    for sku in ["base", "cis-l1", "cis-l2"]:
        meta_dir = f"audit-work/metadata/metadata-{sku}"
        log_dir  = f"audit-work/logs/logs-{sku}"

        manifest_files = sorted(glob.glob(
            f"{meta_dir}/ubuntu-2404-hcs-{sku}-*.manifest.json"
        ))
        sbom_path      = f"{meta_dir}/ubuntu-2404-hcs-{sku}-sbom.tsv"
        checksums_path = f"{meta_dir}/ubuntu-2404-hcs-{sku}-checksums.sha256"
        imginfo_path   = f"{meta_dir}/ubuntu-2404-hcs-{sku}-qemu-img-info.txt"
        serial_path    = f"{log_dir}/serial.log"
        packer_path    = f"{log_dir}/packer.log"

        manifest  = read_json(manifest_files[-1]) if manifest_files else None
        checksums = parse_checksums(checksums_path)
        img_info  = read_text(imginfo_path)
        sbom_pkgs = sbom_package_count(sbom_path)
        serial_lc = (read_text(serial_path) or "").count("\n")
        packer_lc = (read_text(packer_path) or "").count("\n")

        skus[sku] = {
            "build_result":       "success" if manifest else "failed_or_skipped",
            "manifest":           manifest,
            "artifact_sha256":    manifest.get("artifact_sha256") if manifest else None,
            "sbom_package_count": sbom_pkgs,
            "checksums":          checksums,
            "qemu_img_info":      img_info,
            "log_line_counts": {
                "serial_log": serial_lc,
                "packer_log": packer_lc,
            },
        }

    bundle = {
        "audit_schema_version": "1",
        "build_timestamp":      build_ts,
        "audit_generated_utc":  now,
        "pipeline": {
            "provider":     "GitHub Actions",
            "run_id":       run_id,
            "run_number":   run_number,
            "run_url":      f"{server_url}/{repo}/actions/runs/{run_id}",
            "workflow":     workflow,
            "actor":        actor,
            "event":        event_name,
            "ref":          ref,
            "git_sha_full": full_sha,
            "repository":   repo,
        },
        "source": {
            "git_commit_short": git_sha,
            "git_sha_full":     full_sha,
            "ref":              ref,
        },
        "base_image": {
            "name":                "noble-server-cloudimg-amd64.img",
            "url":                 "https://cloud-images.ubuntu.com/noble/current/",
            "sha256":              base_sha,
            "gpg_signing_key":     "D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81",
            "gpg_key_description": "Ubuntu Cloud Image Automatic Signing Key",
            "gpg_verified":        _gpg_verified("audit-work/prepare/gpg-verify.log"),
        },
        "skus": skus,
    }

    out_path = os.path.join(bundle_dir, "audit-bundle.json")
    with open(out_path, "w") as f:
        json.dump(bundle, f, indent=2, default=str)

    # Validate round-trip
    with open(out_path) as f:
        json.load(f)

    size = os.path.getsize(out_path)
    print(f"audit-bundle.json written and validated ({size:,} bytes)")


if __name__ == "__main__":
    main()
