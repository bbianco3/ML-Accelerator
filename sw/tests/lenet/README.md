# lenet: pretrained LeNet-5 inference

`make run TEST=lenet` classifies 16 MNIST test digits on all accelerator
cores and checks the result bit for bit against a C model of the same
arithmetic.

| File | What |
|---|---|
| `kernel.S` | the accelerator program: im2col + GEMM convolutions, bias/ReLU/max-pool, batched fully connected layers |
| `main.c` | host: packs the weights, plans scratchpad/HBM buffers, launches, checks, prints a cycle breakdown |
| `lenet.bin` | trained weights (bf16) + 16 test images and labels, made by `train_lenet.py` |
| `weights.S` | links `lenet.bin` into the host program |
| `train_lenet.py` | numpy-only training script (4 epochs, ~3 minutes); 98.97 % MNIST test accuracy, the same with bf16 weights |

To retrain (only needed if you change the network):

```sh
python3 -m venv venv && venv/bin/pip install numpy
# download the 4 MNIST .gz files, e.g. from https://ossci-datasets.s3.amazonaws.com/mnist/
venv/bin/python train_lenet.py --mnist <dir> --out lenet.bin
```

MNIST is by Y. LeCun, C. Cortes and C. Burges (CC BY-SA 3.0); the 16 images
in `lenet.bin` are test-set images 0-15.

Where the time goes (default configuration, core 0): about 75 % im2col
(scalar copies), 15 % bias/ReLU/pool, under 5 % on the matrix unit. That is
the starting point for the "im2col in hardware" project in
`docs/project-guide.md`.
