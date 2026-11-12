#!/usr/bin/env python3
"""train_lenet.py -- train LeNet-5 on MNIST with numpy only and export the
weights + a few test images for the `lenet` accelerator test.

You do NOT need to run this: its output, lenet.bin, is checked in. It is here
so the weights are reproducible and so you can retrain or change the network.

    python3 -m venv venv && venv/bin/pip install numpy
    venv/bin/python train_lenet.py --mnist DIR --out lenet.bin

DIR must contain the four MNIST files (train-images-idx3-ubyte.gz, ...), e.g.
from https://ossci-datasets.s3.amazonaws.com/mnist/ (the PyTorch mirror).
MNIST: Y. LeCun, C. Cortes, C. Burges, CC BY-SA 3.0.

Network (LeNet-5 with ReLU and max pooling, the usual modern variant):

    input 1x28x28, normalized (x/255 - 0.1307) / 0.3081, zero-padded to 32x32
    conv1  6 x 1x5x5  + bias, ReLU, maxpool 2x2   -> 6x14x14
    conv2 16 x 6x5x5  + bias, ReLU, maxpool 2x2   -> 16x5x5 = 400
    fc1   400 -> 120 + bias, ReLU
    fc2   120 ->  84 + bias, ReLU
    fc3    84 ->  10 + bias                        (logits)

lenet.bin (little-endian):
    char  magic[4] = "LNT1"; uint32 n_images; uint32 test_acc_x100 (fp32 model,
          full test set, in 1/100 %); uint32 test_acc_bf16_x100 (bf16 weights)
    bf16  conv1.w[6][1][5][5], conv1.b[6], conv2.w[16][6][5][5], conv2.b[16],
          fc1.w[120][400], fc1.b[120], fc2.w[84][120], fc2.b[84],
          fc3.w[10][84], fc3.b[10]          (PyTorch layouts, weights rounded
                                             to bf16 with round-to-nearest-even)
    uint8 images[n_images][28][28], labels[n_images], zero padding to 4 bytes
The images are the first test images that the fp32 model classifies correctly
with a clear margin, so the accelerator test checks the hardware, not the
model's accuracy.
"""

import argparse
import gzip
import os
import struct
import sys
import time

import numpy as np

SHAPES = [("conv1.w", (6, 1, 5, 5)), ("conv1.b", (6,)),
          ("conv2.w", (16, 6, 5, 5)), ("conv2.b", (16,)),
          ("fc1.w", (120, 400)), ("fc1.b", (120,)),
          ("fc2.w", (84, 120)), ("fc2.b", (84,)),
          ("fc3.w", (10, 84)), ("fc3.b", (10,))]
MEAN, STD = 0.1307, 0.3081


def load_mnist(d):
    def images(name):
        with gzip.open(os.path.join(d, name)) as f:
            _, n, r, c = struct.unpack(">IIII", f.read(16))
            return np.frombuffer(f.read(), np.uint8).reshape(n, r, c)

    def labels(name):
        with gzip.open(os.path.join(d, name)) as f:
            f.read(8)
            return np.frombuffer(f.read(), np.uint8)

    return (images("train-images-idx3-ubyte.gz"), labels("train-labels-idx1-ubyte.gz"),
            images("t10k-images-idx3-ubyte.gz"), labels("t10k-labels-idx1-ubyte.gz"))


def preprocess(img_u8):
    x = (img_u8.astype(np.float32) / 255.0 - MEAN) / STD
    return np.pad(x, ((0, 0), (2, 2), (2, 2)))[:, None]           # N x 1 x 32 x 32


# --------------------------------------------------------------------------
# Layers (forward + backward), NCHW, stride 1, no padding
# --------------------------------------------------------------------------
def im2col(x, k):
    n, c, h, w = x.shape
    win = np.lib.stride_tricks.sliding_window_view(x, (k, k), axis=(2, 3))  # n c ho wo k k
    ho, wo = h - k + 1, w - k + 1
    return win.transpose(0, 2, 3, 1, 4, 5).reshape(n * ho * wo, c * k * k), ho, wo


def conv_fwd(x, w, b):
    cout, cin, k, _ = w.shape
    cols, ho, wo = im2col(x, k)
    y = cols @ w.reshape(cout, -1).T + b
    return y.reshape(x.shape[0], ho, wo, cout).transpose(0, 3, 1, 2), cols


def conv_bwd(dy, x, w, cols):
    cout, cin, k, _ = w.shape
    n, _, ho, wo = dy.shape
    dyf = dy.transpose(0, 2, 3, 1).reshape(-1, cout)
    dw = (dyf.T @ cols).reshape(w.shape)
    db = dyf.sum(0)
    dcols = (dyf @ w.reshape(cout, -1)).reshape(n, ho, wo, cin, k, k)
    dx = np.zeros_like(x)
    for ky in range(k):
        for kx in range(k):
            dx[:, :, ky:ky + ho, kx:kx + wo] += dcols[:, :, :, :, ky, kx].transpose(0, 3, 1, 2)
    return dx, dw, db


def pool_fwd(x):
    n, c, h, w = x.shape
    r = x.reshape(n, c, h // 2, 2, w // 2, 2)
    y = r.max(axis=(3, 5))
    mask = (r == y[:, :, :, None, :, None])
    return y, mask


def pool_bwd(dy, mask):
    n, c, h2, w2 = dy.shape
    d = mask * dy[:, :, :, None, :, None]
    return d.reshape(n, c, h2 * 2, w2 * 2)


def forward(p, x, keep=False):
    a1, c1 = conv_fwd(x, p["conv1.w"], p["conv1.b"])
    r1 = np.maximum(a1, 0)
    p1, m1 = pool_fwd(r1)
    a2, c2 = conv_fwd(p1, p["conv2.w"], p["conv2.b"])
    r2 = np.maximum(a2, 0)
    p2, m2 = pool_fwd(r2)
    f = p2.reshape(len(x), -1)                                   # CHW flatten (PyTorch)
    h1 = np.maximum(f @ p["fc1.w"].T + p["fc1.b"], 0)
    h2 = np.maximum(h1 @ p["fc2.w"].T + p["fc2.b"], 0)
    out = h2 @ p["fc3.w"].T + p["fc3.b"]
    if keep:
        return out, (x, a1, c1, p1, m1, a2, c2, p2, m2, f, h1, h2)
    return out


def backward(p, cache, dout):
    x, a1, c1, p1, m1, a2, c2, p2, m2, f, h1, h2 = cache
    g = {}
    g["fc3.w"], g["fc3.b"] = dout.T @ h2, dout.sum(0)
    dh2 = (dout @ p["fc3.w"]) * (h2 > 0)
    g["fc2.w"], g["fc2.b"] = dh2.T @ h1, dh2.sum(0)
    dh1 = (dh2 @ p["fc2.w"]) * (h1 > 0)
    g["fc1.w"], g["fc1.b"] = dh1.T @ f, dh1.sum(0)
    df = (dh1 @ p["fc1.w"]).reshape(p2.shape)
    da2 = pool_bwd(df, m2) * (a2 > 0)
    dp1, g["conv2.w"], g["conv2.b"] = conv_bwd(da2, p1, p["conv2.w"], c2)
    da1 = pool_bwd(dp1, m1) * (a1 > 0)
    _, g["conv1.w"], g["conv1.b"] = conv_bwd(da1, x, p["conv1.w"], c1)
    return g


def init_params(rng):
    p = {}
    for name, shape in SHAPES:
        if name.endswith(".w"):
            fan_in = int(np.prod(shape[1:]))
            bound = 1.0 / np.sqrt(fan_in)                        # PyTorch default init
            p[name] = rng.uniform(-bound, bound, shape).astype(np.float32)
            wname = name
        else:
            fan_in = int(np.prod(dict(SHAPES)[wname][1:]))
            p[name] = rng.uniform(-1 / np.sqrt(fan_in), 1 / np.sqrt(fan_in), shape).astype(np.float32)
    return p


def to_bf16_bits(a):
    """fp32 -> bf16 bit patterns, round to nearest even."""
    u = np.ascontiguousarray(a, dtype=np.float32).view(np.uint32).astype(np.uint64)
    u = (u + 0x7FFF + ((u >> 16) & 1)) >> 16
    return u.astype(np.uint16)


def from_bf16_bits(b):
    return (b.astype(np.uint32) << 16).view(np.float32)


def accuracy(p, x, y, bs=1000):
    correct = 0
    for i in range(0, len(x), bs):
        correct += int((forward(p, x[i:i + bs]).argmax(1) == y[i:i + bs]).sum())
    return correct / len(x)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mnist", required=True, help="directory with the MNIST .gz files")
    ap.add_argument("--out", default="lenet.bin")
    ap.add_argument("--epochs", type=int, default=4)
    ap.add_argument("--images", type=int, default=16, help="test images to export")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    xtr_u8, ytr, xte_u8, yte = load_mnist(args.mnist)
    xtr, xte = preprocess(xtr_u8), preprocess(xte_u8)
    rng = np.random.default_rng(args.seed)
    p = init_params(rng)

    # Adam
    lr, b1, b2, eps, bs = 1e-3, 0.9, 0.999, 1e-8, 64
    m = {k: np.zeros_like(v) for k, v in p.items()}
    v = {k: np.zeros_like(v) for k, v in p.items()}
    t = 0
    for ep in range(args.epochs):
        t0 = time.time()
        order = rng.permutation(len(xtr))
        loss_sum = 0.0
        for i in range(0, len(order), bs):
            idx = order[i:i + bs]
            out, cache = forward(p, xtr[idx], keep=True)
            z = out - out.max(1, keepdims=True)
            prob = np.exp(z) / np.exp(z).sum(1, keepdims=True)
            loss_sum += float(-np.log(prob[np.arange(len(idx)), ytr[idx]] + 1e-12).sum())
            dout = prob
            dout[np.arange(len(idx)), ytr[idx]] -= 1
            g = backward(p, cache, dout / len(idx))
            t += 1
            for k in p:
                m[k] = b1 * m[k] + (1 - b1) * g[k]
                v[k] = b2 * v[k] + (1 - b2) * g[k] ** 2
                p[k] -= lr * (m[k] / (1 - b1 ** t)) / (np.sqrt(v[k] / (1 - b2 ** t)) + eps)
        if ep == args.epochs - 2:
            lr *= 0.3
        print(f"epoch {ep + 1}: loss {loss_sum / len(order):.4f}, test acc {100 * accuracy(p, xte, yte):.2f} %"
              f" ({time.time() - t0:.0f} s)", flush=True)

    acc32 = accuracy(p, xte, yte)
    pb = {k: from_bf16_bits(to_bf16_bits(a)).reshape(a.shape) for k, a in p.items()}
    acc16 = accuracy(pb, xte, yte)
    print(f"test accuracy: fp32 weights {100 * acc32:.2f} %, bf16 weights {100 * acc16:.2f} %")

    # Export: confidently classified test images (top-1 margin >= 3 logits)
    out = forward(pb, xte[:2000])
    srt = np.sort(out, 1)
    ok = (out.argmax(1) == yte[:2000]) & (srt[:, -1] - srt[:, -2] >= 3.0)
    sel = np.nonzero(ok)[0][:args.images]
    with open(args.out, "wb") as f:
        f.write(b"LNT1")
        f.write(struct.pack("<III", len(sel), round(acc32 * 10000), round(acc16 * 10000)))
        for name, shape in SHAPES:
            assert p[name].shape == shape
            f.write(to_bf16_bits(p[name]).tobytes())
        f.write(xte_u8[sel].tobytes())
        f.write(yte[sel].tobytes())
        f.write(b"\0" * (-f.tell() % 4))
    print(f"wrote {args.out}: {len(sel)} images (test-set indices {sel.tolist()}), "
          f"labels {yte[sel].tolist()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
