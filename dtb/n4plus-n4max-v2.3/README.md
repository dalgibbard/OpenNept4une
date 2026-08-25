# ZNP-K1 2.3 device tree

`rk3328-znp-n4plus-n4max-v2.3.dts` is a decompiled, numeric-phandle device
tree. Rebuild its committed blob with `dtc`:

```bash
dtc -I dts -O dtb \
  -o rk3328-znp-n4plus-n4max-v2.3.dtb \
  rk3328-znp-n4plus-n4max-v2.3.dts
```

The decompiled source produces phandle-reference warnings; these predate the
board-2.3 work. `tests/test_dtb.py` parses the resulting binary directly and
guards the RK805 interrupt mapping and documented SHA-256.

Physical testing on a `ZNP-K1-2.3` found the inherited RK805 GPIO2 line-24
interrupt storming until Linux disabled it. The corrected value is GPIO2 line
6 (`RK_PA6`), which matches the existing `pmic-int-l` pinctrl entry and the
maintained Armbian MKS Pi device tree:

<https://github.com/armbian/build/blob/e65ba52e3d99004c7dd4e39665e5f9c08516a30a/patch/kernel/archive/rockchip64-6.12/dt/rk3328-mkspi.dts>

Current blob SHA-256:

```text
808c234c5cedb0e5f70d87fc7973d9e2693a7e38563c5ad62c99417b7d22c92b
```
