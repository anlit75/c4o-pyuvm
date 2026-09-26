# apb_uart_sv (vendored)

The DUT. Not ours: copied unmodified from

    https://github.com/pulp-platform/apb_uart_sv
    dfad6e04d19cc9481d3cd2750b45b970dc61271b  (2017-08-03)

under the Solderpad Hardware License 0.51 (`LICENSE` here, and a header in
every file). ETH Zurich and University of Bologna wrote it.

`apb_uart.sv` from that repository is not here: it is a byte-identical copy of
`apb_uart_sv.sv`, declaring the same module, so including both is a
redefinition error.

## Why it is copied in rather than fetched

The upstream repository is archived. A design that cannot be simulated because
somebody else's remote moved is not a starter kit, and `git clone` at build
time would put the network between a reader and their first run.

## Why it is not edited

Verifying a design you can change is a different exercise from verifying one
you cannot, and the second is the one this repository is about. Its bugs stay
in: see the LATCH waiver in `config.yaml`, which is one of them.

The Verilog the tools here actually read is `src/apb_uart_sv.v`, generated from
these files by `make rtl`. Nothing regenerates them.
