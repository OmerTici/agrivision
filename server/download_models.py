"""Build-time script: download pinned model snapshots and write refs/main
so HF_HUB_OFFLINE=1 lookups by repo-id resolve correctly at runtime."""
import os
import pathlib
from huggingface_hub import snapshot_download

MODELS = [
    ("conservationxlabs/miewid-msv3", "4f1d7f2b521149e5fe34bb85f377248ce9971a7d"),
    ("timm/efficientnetv2_rw_m.agc_in1k", "b4040ea1ead4df5099a9062e8f05844cea9a1c42"),
]

hf_home = pathlib.Path(os.environ["HF_HOME"])
for repo, sha in MODELS:
    snapshot_download(repo, revision=sha)
    refs_dir = hf_home / "hub" / ("models--" + repo.replace("/", "--")) / "refs"
    refs_dir.mkdir(exist_ok=True)
    (refs_dir / "main").write_text(sha)
    print(f"Pinned {repo} @ {sha}")
