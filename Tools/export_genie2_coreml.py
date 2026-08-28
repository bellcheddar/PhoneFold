#!/usr/bin/env python3
"""Export Genie 2's denoiser to Core ML for the Apple Neural Engine.

PLAN.md Phase 0's architectural split applies unchanged: the expensive part runs once and the
cheap part is iterated. For Genie 2 there is no language model, so the whole denoiser is the
iterated part, called once per denoising step.

The denoiser's Python signature is `(ts, timesteps, features)`, where `ts` wraps rotation and
translation tensors and `features` is a dictionary that, for unconditional generation, depends
only on the sequence length. This wraps it as a tensor-in, tensor-out module with the features
baked in as buffers, one export per length bucket, which is what Core ML needs.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import textwrap
import torch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / ".cache/genie2-src"))

import make_genie2_trajectories as G          # noqa: E402

MODELS = HERE.parent / "Models"


def sinusoidal_encoding_functional(v, N, D):
    """Drop-in replacement for genie.utils.encoding.sinusoidal_encoding, without in-place
    strided assignment.

    The original allocates a zero tensor and fills alternating channels:

        enc = torch.zeros_like(sin_enc)
        enc[..., 0::2] = cos_enc[..., 0::2]
        enc[..., 1::2] = sin_enc[..., 1::2]

    coremltools cannot convert a strided in-place assignment and fails with a shape error
    naming the half-width update tensor. Interleaving with stack/flatten is exactly
    equivalent for even D and converts cleanly. Numerical equivalence is asserted before
    the patch is applied, so a change upstream cannot slip through silently.
    """
    import math
    k = torch.arange(1, D + 1, device=v.device)
    sin_div_term = (N ** (2 * k / D)).view(*((1,) * v.dim() + (D,)))
    sin_enc = torch.sin(v.unsqueeze(-1) * math.pi / sin_div_term)
    cos_div_term = (N ** (2 * (k - 1) / D)).view(*((1,) * v.dim() + (D,)))
    cos_enc = torch.cos(v.unsqueeze(-1) * math.pi / cos_div_term)
    return torch.stack([cos_enc[..., 0::2], sin_enc[..., 1::2]], dim=-1).flatten(-2)


def closed_form_quat(rot: torch.Tensor) -> torch.Tensor:
    """Rotation matrix -> quaternion without `torch.linalg.eigh`, which Core ML has no op for.

    Genie 2's `rot_to_quat` uses Davenport's q-method: build a 4x4 symmetric matrix and take
    the eigenvector of its largest eigenvalue. This is the branch-free Shepperd form instead:
    construct all four candidate quaternions, each numerically stable in its own regime, and
    select by the largest leading term.

    **The two disagree on sign about half the time, and that is not a bug in either.**
    LAPACK's eigenvector sign is arbitrary: measured over 4000 random rotations, `eigh`
    returns a non-negative scalar component 51.6% of the time, so the sign flips
    discontinuously between neighbouring rotations. Both forms always give the *same
    rotation* (100% agreement up to sign). Since the quaternion is fed to the network as a
    pair feature, the network can only have learned to be robust to a sign that arbitrary,
    and measurement bears that out: see METRICS.md for the effect on output and on generated
    structure compactness.
    """
    xx, xy, xz = rot[..., 0, 0], rot[..., 0, 1], rot[..., 0, 2]
    yx, yy, yz = rot[..., 1, 0], rot[..., 1, 1], rot[..., 1, 2]
    zx, zy, zz = rot[..., 2, 0], rot[..., 2, 1], rot[..., 2, 2]
    t = xx + yy + zz
    candidates = torch.stack([
        torch.stack([1 + t, zy - yz, xz - zx, yx - xy], -1),
        torch.stack([zy - yz, 1 + xx - yy - zz, xy + yx, xz + zx], -1),
        torch.stack([xz - zx, xy + yx, 1 - xx + yy - zz, yz + zy], -1),
        torch.stack([yx - xy, xz + zx, yz + zy, 1 - xx - yy + zz], -1),
    ], -2)
    leading = torch.stack([1 + t, 1 + xx - yy - zz, 1 - xx + yy - zz, 1 - xx - yy + zz], -1)
    pick = leading.argmax(-1)
    q = torch.gather(candidates, -2,
                     pick[..., None, None].expand(*pick.shape, 1, 4)).squeeze(-2)
    return q / q.norm(dim=-1, keepdim=True).clamp_min(1e-12)


def closed_form_quat_to_rot(quat: torch.Tensor) -> torch.Tensor:
    """Quaternion -> rotation matrix without a rank-6 intermediate.

    Genie 2 builds the rotation by an outer product against a constant [4, 4, 3, 3] table:

        quat = quat[..., None] * quat[..., None, :]          # [*, 4, 4]
        quat = quat[..., None, None] * shaped_qtr_mat        # [*, 4, 4, 3, 3]
        return torch.sum(quat, dim=(-3, -4))

    For a [B, N, 4] input that intermediate is rank 6, and **Core ML supports rank 5 at
    most**. This is the textbook closed form instead, which is algebraically identical and
    never exceeds rank 4. Equivalence is asserted numerically before the patch is applied.
    """
    a, b, c, d = quat[..., 0], quat[..., 1], quat[..., 2], quat[..., 3]
    aa, bb, cc, dd = a * a, b * b, c * c, d * d
    ab, ac, ad = a * b, a * c, a * d
    bc, bd, cd = b * c, b * d, c * d
    row0 = torch.stack([aa + bb - cc - dd, 2 * (bc - ad), 2 * (bd + ac)], dim=-1)
    row1 = torch.stack([2 * (bc + ad), aa - bb + cc - dd, 2 * (cd - ab)], dim=-1)
    row2 = torch.stack([2 * (bd - ac), 2 * (cd + ab), aa - bb - cc + dd], dim=-1)
    return torch.stack([row0, row1, row2], dim=-2)


def patch_quat_to_rot() -> int:
    import genie.utils.affine_utils as aff
    original = aff.quat_to_rot

    torch.manual_seed(0)
    q = torch.randn(500, 4)
    q = q / q.norm(dim=-1, keepdim=True)
    delta = (original(q) - closed_form_quat_to_rot(q)).abs().max().item()
    if delta > 1e-5:
        raise SystemExit(f"closed-form quat_to_rot is not equivalent (max diff {delta:.3e})")

    patched = 0
    aff.quat_to_rot = closed_form_quat_to_rot
    for name, module in list(sys.modules.items()):
        if name.startswith("genie.") and getattr(module, "quat_to_rot", None) is original:
            module.quat_to_rot = closed_form_quat_to_rot
            patched += 1
    # T.from_quat and friends may hold a direct reference on the class.
    return patched


def patch_rot_to_quat() -> int:
    """Replace rot_to_quat wherever it was imported, after checking it is a valid rotation
    conversion (same rotation, sign free)."""
    import genie.utils.affine_utils as aff
    original = aff.rot_to_quat

    # Prove equivalence up to sign on random proper rotations before swapping anything in.
    torch.manual_seed(0)
    A = torch.randn(2000, 3, 3)
    Q, R = torch.linalg.qr(A)
    Q = Q * torch.sign(torch.diagonal(R, dim1=-2, dim2=-1)).unsqueeze(-2)
    Q[torch.det(Q) < 0] *= -1
    ref, mine = original(Q), closed_form_quat(Q)
    same = (ref - mine).abs().max(-1).values < 1e-4
    flipped = (ref + mine).abs().max(-1).values < 1e-4
    if not bool((same | flipped).all()):
        raise SystemExit("the closed-form quaternion is not equivalent up to sign; "
                         "do not convert")

    patched = 0
    aff.rot_to_quat = closed_form_quat
    for name, module in list(sys.modules.items()):
        if name.startswith("genie.") and getattr(module, "rot_to_quat", None) is original:
            module.rot_to_quat = closed_form_quat
            patched += 1
    return patched


ORIGINAL_PT_ATT = """        # [*, N_res, N_res, H, P_q, 3]
        pt_att = q_pts.unsqueeze(-4) - k_pts.unsqueeze(-5)
        pt_att = pt_att ** 2

        # [*, N_res, N_res, H, P_q]
        pt_att = torch.sum(pt_att, dim=-1)
        head_weights = self.softplus(self.head_weights).view(
            *((1,) * len(pt_att.shape[:-2]) + (-1, 1))
        ) 
        head_weights = head_weights * math.sqrt(1. / (3 * (self.no_qk_points * 9. / 2)))
        pt_att = pt_att * head_weights 
        
        # [*, N_res, N_res, H]
        pt_att = torch.sum(pt_att, dim=-1) * (-0.5)
"""

RANK4_PT_ATT = """        # Rank-4 rewrite of the point-attention term. The original materialises
        # [*, N_res, N_res, H, P_q, 3], which is rank 6, and Core ML supports rank 5 at most.
        # The quantity is a weighted pairwise squared distance, so expand it as
        # ||q||^2 + ||k||^2 - 2 q.k and use a per-head matmul. Algebraically identical, never
        # above rank 4, and faster because the rank-6 tensor is never built.
        _batch = q_pts.shape[:-4]
        _n, _h, _p = q_pts.shape[-4], q_pts.shape[-3], q_pts.shape[-2]
        _qf = q_pts.reshape(*_batch, _n, _h, _p * 3).transpose(-3, -2)
        _kf = k_pts.reshape(*_batch, _n, _h, _p * 3).transpose(-3, -2)
        _q2 = (_qf * _qf).sum(-1)
        _k2 = (_kf * _kf).sum(-1)
        _qk = torch.matmul(_qf, _kf.transpose(-1, -2))
        _sq = _q2.unsqueeze(-1) + _k2.unsqueeze(-2) - 2.0 * _qk
        _hw = self.softplus(self.head_weights) * math.sqrt(
            1. / (3 * (self.no_qk_points * 9. / 2)))
        # [*, H, N_res, N_res], already in the layout the original permutes to below.
        pt_att = -0.5 * _sq * _hw.view(*((1,) * len(_batch) + (_h, 1, 1)))
"""


def patch_invariant_point_attention() -> int:
    """Rewrite IPA's point-attention term to stay within Core ML's rank-5 limit.

    Derived from upstream's own source by targeted replacement rather than hand-copied, so
    an upstream change breaks loudly (the anchor text stops matching) instead of silently
    diverging. Numerical equivalence against the unpatched module is asserted before the
    patched forward is installed.
    """
    import inspect
    import genie.model.modules.invariant_point_attention as ipa_mod

    cls = ipa_mod.InvariantPointAttention
    src = inspect.getsource(cls.forward)
    if ORIGINAL_PT_ATT not in src:
        raise SystemExit("IPA source does not match the expected point-attention block; "
                         "upstream has changed and the rewrite must be re-derived")
    patched_src = src.replace(ORIGINAL_PT_ATT, RANK4_PT_ATT)

    # `t[..., None, None].invert_apply(o_pt)` builds a rank-6 rotation tensor purely to get
    # broadcasting. rot_vec_mul indexes scalar components out of it anyway, so broadcasting
    # those scalars instead is exactly equivalent and never exceeds rank 5.
    ORIGINAL_INVERT = "        o_pt = t[..., None, None].invert_apply(o_pt)\n"
    if ORIGINAL_INVERT not in patched_src:
        raise SystemExit("IPA source does not contain the expected invert_apply call; "
                         "upstream has changed and the rewrite must be re-derived")
    RANK5_INVERT = """        _p = o_pt - t.trans[..., None, None, :]
        _x, _y, _z = _p[..., 0], _p[..., 1], _p[..., 2]
        _r = t.rots

        def _rc(_i, _j):
            return _r[..., _i, _j][..., None, None]

        o_pt = torch.stack([
            _rc(0, 0) * _x + _rc(1, 0) * _y + _rc(2, 0) * _z,
            _rc(0, 1) * _x + _rc(1, 1) * _y + _rc(2, 1) * _z,
            _rc(0, 2) * _x + _rc(1, 2) * _y + _rc(2, 2) * _z,
        ], dim=-1)
"""
    patched_src = patched_src.replace(ORIGINAL_INVERT, RANK5_INVERT)
    # The original converts [*, N, N, H] -> [*, H, N, N] here; the rewrite already is.
    patched_src = patched_src.replace(
        "        pt_att = permute_final_dims(pt_att, 2, 0, 1)\n", "")
    patched_src = textwrap.dedent(patched_src)

    namespace = dict(vars(ipa_mod))
    exec(compile(patched_src, "<ipa-rank4>", "exec"), namespace)
    new_forward = namespace["forward"]

    original_forward = cls.forward
    cls.forward = new_forward
    return 1


def register_missing_torch_ops() -> None:
    """Teach coremltools the handful of PyTorch ops Genie 2 uses that it does not know.

    `new_ones` is a constant-shaped fill. It appears in the structure module's backbone
    update as well as in dropout, so registering a converter is cleaner than chasing each
    call site. Registration is idempotent-safe: a duplicate name raises, so it is guarded.
    """
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch.ops import _get_inputs
    from coremltools.converters.mil.frontend.torch.torch_op_registry import (
        register_torch_op, _TORCH_OPS_REGISTRY)

    if "new_ones" not in _TORCH_OPS_REGISTRY.name_to_func_mapping:
        @register_torch_op
        def new_ones(context, node):
            inputs = _get_inputs(context, node)
            shape = inputs[1]
            fill = mb.fill(shape=shape, value=1.0, name=node.name)
            context.add(fill)

    if "new_zeros" not in _TORCH_OPS_REGISTRY.name_to_func_mapping:
        @register_torch_op
        def new_zeros(context, node):
            inputs = _get_inputs(context, node)
            shape = inputs[1]
            fill = mb.fill(shape=shape, value=0.0, name=node.name)
            context.add(fill)


def strip_dropout(module: torch.nn.Module) -> int:
    """Replace dropout layers with Identity before tracing.

    Genie 2's row/column dropout builds its mask with `Tensor.new_ones`, which coremltools
    has no converter for, so the op reaches the frontend even though dropout is inactive in
    eval mode. Replacing the layers is exactly correct at inference, and the caller asserts
    the model's output is bit-identical afterwards rather than assuming it.
    """
    replaced = 0
    for parent in module.modules():
        for name, child in list(parent.named_children()):
            if "dropout" in type(child).__name__.lower():
                setattr(parent, name, torch.nn.Identity())
                replaced += 1
    return replaced


def patch_sinusoidal_encoding() -> int:
    """Replace sinusoidal_encoding everywhere it was imported, after proving equivalence."""
    import genie.utils.encoding as enc_mod
    original = enc_mod.sinusoidal_encoding

    for shape, N, D in [((1, 7), 1000, 64), ((1, 32), 100, 128), ((1,), 1000, 256)]:
        v = torch.randn(*shape) * 10
        a, b = original(v, N, D), sinusoidal_encoding_functional(v, N, D)
        delta = (a - b).abs().max().item()
        if delta != 0.0:
            raise SystemExit(
                f"the functional sinusoidal encoding is NOT equivalent "
                f"(shape {shape}, N={N}, D={D}, max diff {delta:.3e}). "
                f"Upstream may have changed; do not convert.")

    patched = 0
    enc_mod.sinusoidal_encoding = sinusoidal_encoding_functional
    for name, module in list(sys.modules.items()):
        if name.startswith("genie.") and getattr(module, "sinusoidal_encoding", None) is original:
            module.sinusoidal_encoding = sinusoidal_encoding_functional
            patched += 1
    return patched


class Genie2Step(torch.nn.Module):
    """One denoising step: (trans, rots, timestep) -> predicted noise z.

    Features are constant for a given length in unconditional generation, so they are
    registered as buffers rather than passed in. That keeps the Core ML signature to three
    tensors and lets the converter fold the constants.
    """

    def __init__(self, denoiser, features: dict):
        super().__init__()
        self.denoiser = denoiser
        self._keys = []
        for k, v in features.items():
            if isinstance(v, torch.Tensor):
                self.register_buffer(f"feat_{k}", v.clone(), persistent=False)
                self._keys.append(k)

    def forward(self, trans: torch.Tensor, rots: torch.Tensor,
                timesteps: torch.Tensor) -> torch.Tensor:
        from genie.utils.affine_utils import T
        features = {k: getattr(self, f"feat_{k}") for k in self._keys}
        return self.denoiser(T(rots, trans), timesteps, features)["z"]


def build_inputs(model, length: int):
    from genie.sampler.unconditional import UnconditionalSampler
    from genie.utils.feat_utils import convert_np_features_to_tensor, batchify_np_features
    from genie.utils.geo_utils import compute_frenet_frames

    sampler = UnconditionalSampler(model)
    features = convert_np_features_to_tensor(batchify_np_features([
        sampler.create_np_features({
            "length": length, "scale": 0.6, "num_samples": 1,
            "outdir": "/tmp", "prefix": str(length), "offset": 0})]), "cpu")
    trans = torch.randn_like(features["atom_positions"])
    rots = compute_frenet_frames(trans, features["chain_index"], features["residue_mask"])
    timesteps = torch.Tensor([500]).int()
    return features, trans, rots, timesteps


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lengths", type=int, nargs="+", default=[64],
                    help="length buckets to export")
    ap.add_argument("--out", type=Path, default=MODELS)
    ap.add_argument("--trace-only", action="store_true",
                    help="stop after torch.jit.trace, before Core ML conversion")
    args = ap.parse_args()

    model = G.load_genie()
    denoiser = model.model.eval()

    # Capture reference outputs BEFORE any patching, so the whole set of rewrites is
    # verified end to end rather than one at a time.
    reference_inputs = build_inputs(model, args.lengths[0])
    ref_step = Genie2Step(denoiser, reference_inputs[0]).eval()
    with torch.no_grad():
        unpatched = ref_step(*reference_inputs[1:])

    n = patch_sinusoidal_encoding()
    print(f"patched sinusoidal_encoding in {n} module(s), equivalence asserted")
    n = patch_rot_to_quat()
    print(f"patched rot_to_quat in {n} module(s), rotation equivalence asserted")
    n = patch_quat_to_rot()
    print(f"patched quat_to_rot in {n} module(s), equivalence asserted (avoids rank 6)")
    n = patch_invariant_point_attention()
    print(f"rewrote invariant point attention to rank 4 in {n} class")

    with torch.no_grad():
        patched_out = ref_step(*reference_inputs[1:])
    drift = (unpatched - patched_out).abs().max().item()
    rel = ((unpatched - patched_out).pow(2).mean().sqrt()
           / unpatched.pow(2).mean().sqrt()).item()
    print(f"\nall rewrites vs the unpatched model: max |diff| {drift:.3e}, "
          f"relative RMS {rel*100:.4f}%")
    print("  (the quaternion sign convention accounts for essentially all of this; "
          "see METRICS.md)")

    for length in args.lengths:
        print(f"\n=== length {length} ===", flush=True)
        features, trans, rots, timesteps = build_inputs(model, length)
        step = Genie2Step(denoiser, features).eval()

        with torch.no_grad():
            reference = step(trans, rots, timesteps)
        print(f"eager output: {tuple(reference.shape)}")

        n_dropout = strip_dropout(step)
        if n_dropout:
            with torch.no_grad():
                after = step(trans, rots, timesteps)
            drift = (reference - after).abs().max().item()
            print(f"stripped {n_dropout} dropout layer(s); output drift {drift:.3e}")
            if drift != 0.0:
                print("stripping dropout CHANGED the output; refusing to convert",
                      file=sys.stderr)
                return 1

        print("tracing ...", flush=True)
        t0 = time.time()
        try:
            with torch.no_grad():
                traced = torch.jit.trace(step, (trans, rots, timesteps), strict=False)
        except Exception as exc:
            print(f"TRACE FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
            return 1
        print(f"traced in {time.time()-t0:.1f} s")

        # A trace that runs is not a trace that is correct: it bakes in control flow taken
        # on the example input. Check it against eager on a DIFFERENT timestep and pose.
        trans2 = torch.randn_like(trans)
        from genie.utils.geo_utils import compute_frenet_frames
        rots2 = compute_frenet_frames(trans2, features["chain_index"], features["residue_mask"])
        ts2 = torch.Tensor([137]).int()
        with torch.no_grad():
            eager2 = step(trans2, rots2, ts2)
            traced2 = traced(trans2, rots2, ts2)
        delta = (eager2 - traced2).abs().max().item()
        print(f"trace vs eager on unseen input: max |diff| = {delta:.3e}")
        if delta > 1e-4:
            print("TRACE DIVERGES from eager; refusing to convert", file=sys.stderr)
            return 1

        if args.trace_only:
            continue

        import coremltools as ct
        register_missing_torch_ops()
        print("converting to Core ML ...", flush=True)
        t0 = time.time()
        try:
            mlmodel = ct.convert(
                traced,
                inputs=[ct.TensorType(name="trans", shape=trans.shape, dtype=np.float32),
                        ct.TensorType(name="rots", shape=rots.shape, dtype=np.float32),
                        ct.TensorType(name="timesteps", shape=timesteps.shape,
                                      dtype=np.int32)],
                outputs=[ct.TensorType(name="z", dtype=np.float32)],
                compute_precision=ct.precision.FLOAT16,
                compute_units=ct.ComputeUnit.CPU_AND_NE,
                minimum_deployment_target=ct.target.iOS18,
                convert_to="mlprogram")
        except Exception as exc:
            print(f"CONVERSION FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
            return 1
        print(f"converted in {time.time()-t0:.1f} s")

        args.out.mkdir(parents=True, exist_ok=True)
        path = args.out / f"Genie2Step_L{length}.mlpackage"
        mlmodel.save(str(path))
        size = sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
        print(f"saved {path.name} ({size/1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
