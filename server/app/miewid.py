"""Vendored MiewID-msv3 embedder.

Source of truth: Animal_Biometrics_System/cattle_id_bakeoff/scripts/models/
miewid_msv3.py (the exact code the bakeoff results were produced with).
Per the model card: 440x440 input, ImageNet normalization, model(batch)
returns the embedding tensor directly. Output: 2152-d, L2-normalized."""
import numpy as np
import torch

# Cloud Run CPUs lack NNPACK support; disable it up front to silence the
# benign "Could not initialize NNPACK" warnings on every cold start.
torch.backends.nnpack.set_flags(False)

import torchvision.transforms as T
from transformers import AutoModel

HF_ID = "conservationxlabs/miewid-msv3"
EMB_DIM = 2152


def _compat_shim():
    """MiewID's remote modeling code predates transformers 5.x, which expects
    every PreTrainedModel to expose `all_tied_weights_keys` during
    from_pretrained's weight-tying step. Provide a harmless class-level default
    (MiewID has no tied weights)."""
    try:
        from transformers import PreTrainedModel
        if not hasattr(PreTrainedModel, "all_tied_weights_keys"):
            PreTrainedModel.all_tied_weights_keys = {}
    except Exception:
        pass


class MiewIDEmbedder:
    def __init__(self, device: str = "cpu"):
        self.device = device
        _compat_shim()
        self.model = (
            AutoModel.from_pretrained(HF_ID, trust_remote_code=True).eval().to(device)
        )
        # Preprocessing taken verbatim from the model card (do not assume).
        self.tfm = T.Compose([
            T.Resize((440, 440)),
            T.ToTensor(),
            T.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
        ])

    def _feats(self, batch: torch.Tensor) -> torch.Tensor:
        out = self.model(batch)
        if hasattr(out, "shape"):  # custom model returns the tensor directly
            return out
        for attr in ("pooler_output", "last_hidden_state", "logits"):
            if getattr(out, attr, None) is not None:
                return getattr(out, attr)
        raise RuntimeError(f"unexpected MiewID output type: {type(out)}")

    @torch.no_grad()
    def embed_batch(self, pil_images) -> np.ndarray:
        batch = torch.stack([self.tfm(im.convert("RGB")) for im in pil_images]).to(self.device)
        feats = torch.nn.functional.normalize(self._feats(batch), p=2, dim=1)
        arr = feats.detach().cpu().numpy().astype(np.float32)
        assert arr.shape[1] == EMB_DIM, f"expected {EMB_DIM}-d, got {arr.shape[1]}"
        assert np.all(np.abs(np.linalg.norm(arr, axis=1) - 1.0) < 1e-3), "not L2-normalized"
        return arr
