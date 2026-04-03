#!/usr/bin/env python3
"""E2E load test: authenticate → presign 50 docs → upload → confirm."""

from dotenv import load_dotenv
import os
import random
import string
import sys
from dataclasses import dataclass
from pathlib import Path

import httpx

load_dotenv()


@dataclass
class Flags:
    xml: bool = False
    pdf: bool = False


# ── Config ────────────────────────────────────────────────────────────────────
SUPABASE_URL = "http://localhost:54321"
SUPABASE_ANON_KEY = os.environ["SUPABASE_ANON_KEY"]
API_URL = os.environ.get("API_URL", "http://localhost:8000")
EMAIL = os.environ["TEST_EMAIL"]
PASSWORD = os.environ["TEST_PASSWORD"]
NFS_DIR = Path(os.environ.get("NFS_DIR", Path.home() / "Documents" / "NFs"))
TOTAL_FILES = int(os.environ.get("TOTAL_FILES", 50))

# ── Helpers ───────────────────────────────────────────────────────────────────


def random_suffix(n: int = 8) -> str:
    return "".join(random.choices(string.ascii_lowercase + string.digits, k=n))


def build_file_pool(flags: Flags) -> list[dict]:
    """Collect all available NF files with their metadata."""
    pool = []
    if flags.pdf:
        for path in NFS_DIR.glob("pdf/*.pdf"):
            pool.append({"path": path, "mime_type": "application/pdf", "ext": "pdf"})

    if flags.xml:
        for path in NFS_DIR.glob("xml/*.xml"):
            pool.append({"path": path, "mime_type": "application/xml", "ext": "xml"})
    return pool


# ── Step 1: Authenticate ──────────────────────────────────────────────────────


def authenticate(client: httpx.Client) -> str:
    print("→ Authenticating...")
    print(f"{SUPABASE_URL}/auth/v1/token")
    resp = client.post(
        f"{SUPABASE_URL}/auth/v1/token",
        params={"grant_type": "password"},
        json={"email": EMAIL, "password": PASSWORD},
        headers={"apikey": SUPABASE_ANON_KEY},
    )
    if resp.status_code != 200:
        print(f"  ✗ Auth failed: {resp.status_code} {resp.text}")
        sys.exit(1)
    token = resp.json()["access_token"]
    print(f"  ✓ Got access token (…{token[-12:]})")
    return token


# ── Step 2: Presign ───────────────────────────────────────────────────────────


def presign_batch(client: httpx.Client, token: str, files: list[dict]) -> dict:
    print(f"\n→ Presigning batch of {len(files)} documents...")
    documents = [
        {
            "filename": f["generated_name"],
            "mime_type": f["mime_type"],
            "file_size": f["file_size"],
        }
        for f in files
    ]
    resp = client.post(
        f"{API_URL}/api/v1/batches/presign",
        json={"documents": documents},
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    if resp.status_code != 202:
        print(f"  ✗ Presign failed: {resp.status_code} {resp.text}")
        sys.exit(1)
    data = resp.json()
    batch_id = data["batch_id"]
    print(f"  ✓ Batch created: {batch_id}")
    print(f"  ✓ Received {len(data['documents'])} presigned URLs")
    return data


# ── Step 3: Upload ────────────────────────────────────────────────────────────


def upload_files(
    client: httpx.Client, files: list[dict], presign_data: dict
) -> list[str]:
    print(f"\n→ Uploading {len(files)} files to presigned URLs...")
    docs_by_name = {f["generated_name"]: f for f in files}
    confirmed_ids = []
    failed = []

    for i, doc in enumerate(presign_data["documents"], 1):
        # Match by position (presign response preserves order)
        file_meta = files[i - 1]
        # Presigned URLs reference host.docker.internal (Docker-internal hostname).
        # Rewrite to localhost so the script can reach Supabase Storage from the host.
        upload_url = doc["upload_url"].replace("host.docker.internal", "localhost")
        document_id = doc["document_id"]
        file_path = file_meta["path"]

        file_bytes = file_path.read_bytes()
        resp = client.put(
            upload_url,
            content=file_bytes,
            headers={"Content-Type": file_meta["mime_type"]},
            timeout=60,
        )
        if resp.status_code in (200, 201):
            confirmed_ids.append(document_id)
            print(
                f"  ✓ [{i:02d}/{len(files)}] {file_meta['generated_name']} → {resp.status_code}"
            )
        else:
            failed.append(document_id)
            print(
                f"  ✗ [{i:02d}/{len(files)}] {file_meta['generated_name']} → {resp.status_code}: {resp.text[:100]}"
            )

    print(f"\n  Uploaded: {len(confirmed_ids)} ✓  Failed: {len(failed)} ✗")
    return confirmed_ids


# ── Step 4: Confirm ───────────────────────────────────────────────────────────


def confirm_batch(
    client: httpx.Client, token: str, batch_id: str, document_ids: list[str]
) -> None:
    print(f"\n→ Confirming {len(document_ids)} uploads for batch {batch_id}...")
    resp = client.post(
        f"{API_URL}/api/v1/batches/{batch_id}/confirm",
        json={"document_ids": document_ids},
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    if resp.status_code != 200:
        print(f"  ✗ Confirm failed: {resp.status_code} {resp.text}")
        sys.exit(1)
    data = resp.json()
    confirmed = len(data.get("confirmed", []))
    failed = data.get("failed", [])
    print(f"  ✓ Confirmed: {confirmed}  Failed: {len(failed)}")
    if failed:
        for f in failed:
            print(f"    ✗ {f['document_id']}: {f['reason']}")


# ── Main ──────────────────────────────────────────────────────────────────────


def main(flags: Flags):
    pool = build_file_pool(flags)
    if not pool:
        print("✗ No files found in ~/Documents/NFs/{pdf,xml}/")
        sys.exit(1)
    print(
        f"File pool: {len(pool)} files ({sum(1 for f in pool if f['ext'] == 'pdf')} PDFs, {sum(1 for f in pool if f['ext'] == 'xml')} XMLs)"
    )

    # Pick 50 files randomly (with repetition), assign generated names
    selected = []
    for _ in range(TOTAL_FILES):
        f = random.choice(pool).copy()
        base = random_suffix(10)
        f["generated_name"] = f"{base}.{f['ext']}"
        f["file_size"] = f["path"].stat().st_size
        selected.append(f)

    print(f"Selected {len(selected)} files for upload\n")

    with httpx.Client() as client:
        token = authenticate(client)
        presign_data = presign_batch(client, token, selected)
        confirmed_ids = upload_files(client, selected, presign_data)
        if confirmed_ids:
            confirm_batch(client, token, presign_data["batch_id"], confirmed_ids)

    print("\n✓ Load test complete.")
    print(f"  Batch ID: {presign_data['batch_id']}")


if __name__ == "__main__":
    flags = Flags(xml="--xml" in sys.argv, pdf="--pdf" in sys.argv)
    main(flags)
