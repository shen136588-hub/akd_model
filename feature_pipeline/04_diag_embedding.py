#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
04_diag_embedding.py  (v2 feature pipeline step 4)
Author: mihao for zhaoyang    Date: 2026-07-26

Full BioClinicalBERT (frozen) mean-pool sentence embedding (768d) for diagnosis
text, optional PCA (fit on TRAIN only), merged into per-split static tensor.

Fixes old-version issues:
  * old use_only_embedding=True -> only word-embedding layer, no context
  * old nn.Linear(768,32) random init & untrained -> 32d pure noise
  * this version: full encoder forward + attention-masked mean-pool -> 768d,
    then PCA to --pca_dim (fit on train), no leakage.

Usage:
  python 04_diag_embedding.py --indir assembled_A --dataset dataset_A --pca_dim 32
"""
import argparse
import json
import os

import joblib
import numpy as np
import pandas as pd
import torch
from sklearn.decomposition import PCA
from transformers import AutoModel, AutoTokenizer

MODEL_NAME = "emilyalsentzer/Bio_ClinicalBERT"


def _resolve_local_model():
    """优先用本地 HF 缓存 snapshot (含 model.safetensors), 彻底离线."""
    import glob
    root = os.path.join(
        os.path.expanduser("~"), ".cache", "huggingface", "hub",
        "models--emilyalsentzer--Bio_ClinicalBERT", "snapshots",
    )
    for snap in glob.glob(os.path.join(root, "*")):
        if os.path.exists(os.path.join(snap, "model.safetensors")) and \
           os.path.exists(os.path.join(snap, "config.json")) and \
           os.path.exists(os.path.join(snap, "vocab.txt")):
            return snap
    return MODEL_NAME


@torch.no_grad()
def encode_texts(texts, batch_size=128, max_length=128, use_gpu=True, ckpt=None):
    device = torch.device("cuda" if (use_gpu and torch.cuda.is_available()) else "cpu")
    print("    device=", device, flush=True)
    src = _resolve_local_model()
    print("    model src=", src, flush=True)
    tok = AutoTokenizer.from_pretrained(src)
    model = AutoModel.from_pretrained(src, use_safetensors=True).to(device)
    model.eval()
    # 断点续跑: 已完成的 batch 落盘, 重启后跳过
    n = len(texts)
    done = 0
    parts = []
    if ckpt and os.path.exists(ckpt):
        d = np.load(ckpt)
        arr = d["emb"]
        done = int(d["done"])
        if done > 0:
            parts.append(arr[:done])
            print("    resume from", done, "/", n, flush=True)
    for i in range(done, n, batch_size):
        batch = [t if isinstance(t, str) and t.strip() else "" for t in texts[i:i + batch_size]]
        enc = tok(batch, truncation=True, max_length=max_length,
                  padding="max_length", return_tensors="pt").to(device)
        hidden = model(**enc).last_hidden_state
        m = enc["attention_mask"].unsqueeze(-1).float()
        summed = (hidden * m).sum(1)
        cnt = m.sum(1).clamp(min=1e-9)
        emb = (summed / cnt).cpu().numpy().astype(np.float32)
        parts.append(emb)
        cur = i + len(batch)
        if ckpt and (i // batch_size) % 5 == 0:
            np.savez(ckpt, emb=np.vstack(parts), done=cur)
        if (i // batch_size) % 5 == 0:
            print("    encoded", cur, "/", n, flush=True)
    out = np.vstack(parts).astype(np.float32)
    if ckpt:
        np.savez(ckpt, emb=out, done=n)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--indir", required=True)
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--pca_dim", type=int, default=32)
    ap.add_argument("--no_gpu", action="store_true")
    args = ap.parse_args()

    diag = pd.read_parquet(os.path.join(args.indir, "diag.parquet"))
    split_ids = json.load(open(os.path.join(args.dataset, "split_ids.json"), encoding="utf-8"))

    diag["diag_text"] = diag["diag_text"].fillna("")
    uniq = diag["diag_text"].drop_duplicates().tolist()
    print(">>> unique diag texts", len(uniq), "total", len(diag))
    ckpt = os.path.join(args.dataset, "_diag_emb_ckpt.npz")
    uemb = encode_texts(uniq, use_gpu=not args.no_gpu, ckpt=ckpt)
    text2emb = {t: uemb[i] for i, t in enumerate(uniq)}
    emb = np.vstack([text2emb[t] for t in diag["diag_text"]]).astype(np.float32)
    emb_dim_raw = emb.shape[1]
    print(">>> BERT mean-pool embedding", emb.shape)

    train_ids = set(split_ids["train"])
    tr_mask = diag["stay_id"].isin(train_ids).to_numpy()
    pca = PCA(n_components=min(args.pca_dim, emb.shape[1]), random_state=42)
    pca.fit(emb[tr_mask])
    emb_pca_all = pca.transform(emb).astype(np.float32)
    stay2pca = {sid: emb_pca_all[i] for i, sid in enumerate(diag["stay_id"].tolist())}
    evr = float(pca.explained_variance_ratio_.sum())
    print(">>> PCA", args.pca_dim, "dims, cum EVR", round(evr, 4))

    for k in ["train", "val", "test"]:
        z = np.load(os.path.join(args.dataset, k + ".npz"))
        sids = z["stay_id"]
        diag_feat = np.vstack([
            stay2pca.get(s, np.zeros(args.pca_dim, np.float32)) for s in sids
        ]).astype(np.float32)
        X_static_full = np.concatenate([z["X_static"], diag_feat], axis=1)
        np.savez_compressed(
            os.path.join(args.dataset, k + "_final.npz"),
            X_ts=z["X_ts"], mask=z["mask"],
            X_static=X_static_full, y=z["y"], stay_id=sids,
        )
        print("    ", k, "_final X_static", X_static_full.shape,
              "y+", int(z["y"].sum()), "/", len(z["y"]))

    joblib.dump(pca, os.path.join(args.dataset, "diag_pca.pkl"))
    np.save(os.path.join(args.dataset, "diag_bert_raw_emb.npy"), emb)
    fmeta = json.load(open(os.path.join(args.dataset, "feature_meta.json"), encoding="utf-8"))
    fmeta["diag_embed_dim"] = args.pca_dim
    fmeta["diag_embed_raw_dim"] = emb_dim_raw
    fmeta["diag_pca_evr"] = evr
    fmeta["static_feature_cols_final"] = (
        fmeta["static_feature_cols"] + ["diag_pca_" + str(i) for i in range(args.pca_dim)]
    )
    fmeta["n_static_features_final"] = fmeta["n_static_features"] + args.pca_dim
    fout = open(os.path.join(args.dataset, "feature_meta.json"), "w", encoding="utf-8")
    json.dump(fmeta, fout, ensure_ascii=False, indent=2)
    fout.close()
    print(">>> done. final static feature count =", fmeta["n_static_features_final"])


if __name__ == "__main__":
    main()
