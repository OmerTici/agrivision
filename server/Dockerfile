FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    HF_HOME=/opt/hf

WORKDIR /srv

# Torch CPU wheels first (separate index) — own layer, survives requirements.txt edits.
RUN pip install --no-cache-dir torch==2.12.0 torchvision==0.27.0 \
      --index-url https://download.pytorch.org/whl/cpu

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Bake the MiewID weights into the image: no startup download, cold start
# stays ~20-30 s, and runtime has no HuggingFace dependency.
# Also pre-fetch the timm EfficientNetV2-M backbone that MiewID loads via
# timm.create_model(..., pretrained=True) — it lives in a separate HF repo.
# Revisions pinned so a silent upstream weight update can never change the
# embedding space (stored gallery vectors would stop matching).
# refs/main is also written so HF_HUB_OFFLINE lookups by repo-id resolve correctly.
COPY download_models.py .
RUN python download_models.py
ENV HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1

COPY app ./app

ENV PORT=8080
CMD exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --workers 1
