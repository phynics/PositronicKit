#!/usr/bin/env bash
set -euo pipefail

revision="5f1b8cd78bc4fb444dd171e59b18f3a3af89a079"
prefix="${PKFASTEMBED_PREFIX:?Set PKFASTEMBED_PREFIX}"
model_dir="${PK_MINILM_MODEL_DIR:?Set PK_MINILM_MODEL_DIR}"
manifest="native/pkfastembed/model-assets.sha256"

mkdir -p "$model_dir"
while read -r _ file; do
  if [[ ! -f "$model_dir/$file" ]]; then
    curl --fail --location --retry 3 \
      "https://huggingface.co/Qdrant/all-MiniLM-L6-v2-onnx/resolve/$revision/$file" \
      --output "$model_dir/$file"
  fi
done < "$manifest"

(cd "$model_dir" && shasum -a 256 --check "$OLDPWD/$manifest")
native/pkfastembed/bootstrap.sh --prefix "$prefix"
