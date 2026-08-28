#!/usr/bin/env python3
"""Train the CA-only secondary structure classifier and export it for Swift.

A small multilayer perceptron over the CA-only features in `sse_features.py`, followed by
Viterbi smoothing with a transition matrix estimated from the training labels. The smoothing
matters: per-residue classification alone produces one-residue helices, which are neither
physical nor watchable.

Held out properly:

* The **ten evaluation structures never enter this pipeline at all** - they are excluded in
  `build_sse_dataset.py` by PDB id, and the exclusion list travels with the dataset.
* Train and validation are split **by chain**, never by residue. Splitting by residue would
  put neighbouring residues of the same helix on both sides and inflate the score.

Exports `Models/sse_classifier.json`: weights, biases and the transition matrix. A few tens of
kilobytes, evaluated in plain Swift with no framework.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import sse_features as F                                          # noqa: E402

DATASET = HERE / ".cache/sse_dataset.npz"
OUT = HERE.parent / "Models/sse_classifier.json"
CLASS_NAMES = ["helix", "sheet", "coil"]

HIDDEN = [64, 32]
EPOCHS = 60
BATCH = 4096
LR = 2e-3
SEED = 1


class MLP(nn.Module):
    def __init__(self, n_features: int):
        super().__init__()
        sizes = [n_features] + HIDDEN
        layers = []
        for a, b in zip(sizes[:-1], sizes[1:]):
            layers += [nn.Linear(a, b), nn.ReLU()]
        layers.append(nn.Linear(sizes[-1], 3))
        self.net = nn.Sequential(*layers)

    def forward(self, x):
        return self.net(x)


def viterbi(log_emissions: np.ndarray, log_transitions: np.ndarray) -> np.ndarray:
    """Most likely state path. Mirrored exactly by the Swift implementation."""
    n, k = log_emissions.shape
    score = log_emissions[0].copy()
    back = np.zeros((n, k), dtype="i8")
    for i in range(1, n):
        total = score[:, None] + log_transitions
        back[i] = total.argmax(0)
        score = total.max(0) + log_emissions[i]
    path = np.zeros(n, dtype="i8")
    path[-1] = int(score.argmax())
    for i in range(n - 1, 0, -1):
        path[i - 1] = back[i, path[i]]
    return path


def main() -> int:
    if not DATASET.exists():
        print(f"missing {DATASET}; run build_sse_dataset.py first", file=sys.stderr)
        return 2
    data = np.load(DATASET, allow_pickle=False)
    X, y, groups = data["X"], data["y"], data["groups"]
    chains = data["chains"]
    print(f"dataset: {len(chains)} chains, {len(y)} residues, {X.shape[1]} features")
    print(f"excluded from the dataset entirely: {list(data['excluded'])}")

    rng = np.random.default_rng(SEED)
    chain_ids = np.unique(groups)
    rng.shuffle(chain_ids)
    cut = int(len(chain_ids) * 0.85)
    train_chains, val_chains = set(chain_ids[:cut]), set(chain_ids[cut:])
    train_mask = np.isin(groups, list(train_chains))
    val_mask = np.isin(groups, list(val_chains))
    print(f"split by chain: {len(train_chains)} train, {len(val_chains)} validation")

    torch.manual_seed(SEED)
    model = MLP(X.shape[1])
    optimiser = torch.optim.AdamW(model.parameters(), lr=LR, weight_decay=1e-4)
    # Class weights: coil dominates, and an unweighted fit under-calls helix and sheet.
    counts = np.bincount(y[train_mask], minlength=3).astype("f8")
    weights = torch.tensor((counts.sum() / (3 * counts)), dtype=torch.float32)
    loss_fn = nn.CrossEntropyLoss(weight=weights)

    Xtr = torch.tensor(X[train_mask]); ytr = torch.tensor(y[train_mask])
    Xva = torch.tensor(X[val_mask]); yva = torch.tensor(y[val_mask])

    best_state, best_acc = None, 0.0
    for epoch in range(EPOCHS):
        model.train()
        order = torch.randperm(len(Xtr))
        for start in range(0, len(order), BATCH):
            idx = order[start:start + BATCH]
            optimiser.zero_grad()
            loss = loss_fn(model(Xtr[idx]), ytr[idx])
            loss.backward()
            optimiser.step()
        model.eval()
        with torch.no_grad():
            acc = (model(Xva).argmax(1) == yva).float().mean().item()
        if acc > best_acc:
            best_acc, best_state = acc, {k: v.clone() for k, v in model.state_dict().items()}
        if epoch % 10 == 0 or epoch == EPOCHS - 1:
            print(f"  epoch {epoch:>3}  val per-residue {acc*100:5.2f}%")
    model.load_state_dict(best_state)
    print(f"best validation accuracy before smoothing: {best_acc*100:.2f}%")

    # Transition matrix from training labels, per chain so chain ends do not create
    # transitions that never happen.
    trans = np.ones((3, 3))                          # Laplace smoothing
    for chain in train_chains:
        labels = y[groups == chain]
        for a, b in zip(labels[:-1], labels[1:]):
            trans[a, b] += 1
    trans = trans / trans.sum(1, keepdims=True)
    log_trans = np.log(trans)

    # Validation accuracy after Viterbi, evaluated per chain.
    model.eval()
    total = matched = 0
    with torch.no_grad():
        for chain in val_chains:
            mask = groups == chain
            logits = model(torch.tensor(X[mask])).numpy()
            logp = logits - logits.max(1, keepdims=True)
            logp = logp - np.log(np.exp(logp).sum(1, keepdims=True))
            path = viterbi(logp, log_trans)
            matched += int((path == y[mask]).sum())
            total += int(mask.sum())
    print(f"validation accuracy after Viterbi: {matched/total*100:.2f}%")

    state = model.state_dict()
    layers = []
    for i in range(0, len(model.net), 2):
        linear = model.net[i]
        layers.append({
            "weight": linear.weight.detach().numpy().tolist(),   # [out][in]
            "bias": linear.bias.detach().numpy().tolist(),
            "relu": i + 1 < len(model.net),
        })
    payload = {
        "note": ("CA-only secondary structure classifier for PhoneFold. Features are defined "
                 "by Tools/sse_features.py and must be mirrored exactly in Swift. Trained on "
                 f"{len(train_chains)} PDB chains with mkdssp labels; the ten evaluation "
                 "structures were excluded from the dataset entirely."),
        "classes": CLASS_NAMES,
        "featureCount": int(X.shape[1]),
        "window": F.WINDOW,
        "shells": F.SHELLS,
        "minSeparation": F.MIN_SEPARATION,
        "layers": layers,
        "logTransitions": log_trans.tolist(),
        "validationAccuracy": round(matched / total * 100, 2),
        "trainingChains": int(len(train_chains)),
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(payload) + "\n")
    n_params = sum(p.numel() for p in model.parameters())
    print(f"\n{n_params} parameters -> {OUT} ({OUT.stat().st_size/1000:.0f} kB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
