<div align="center">

# c4o-pyuvm

**一個分層的 pyuvm 測試平台，驗別人寫的 UART，一路做到 GDS。**

同一份測試跑在 RTL 和 gate 上。暫存器模型由一個 SystemRDL 檔生成。

[線上結果](https://anlit75.github.io/c4o-pyuvm/) · [指南](docs/guide.zh-TW.md) · [ChipForAll](https://github.com/anlit75/ChipForAll/blob/main/README.zh-TW.md) · [English](README.md)

![CI](https://github.com/anlit75/c4o-pyuvm/actions/workflows/verify.yml/badge.svg)
[![License](https://img.shields.io/github/license/anlit75/c4o-pyuvm)](LICENSE)

</div>

## 它跟別人不一樣的地方

**在不屬於你的 UART 上，搭一個分層的環境。** 一個 APB agent、一個 scoreboard 和一個 UVM 暫存器模型，驗一顆 16550 風格的 APB UART。DUT 原封不動地 vendored 進來。

**暫存器圖只有一份。** `make ral` 從 `regs/apb_uart.rdl` 生成暫存器模型。CI 會重新生成並 diff，所以圖和模型不可能漂移。

**一份測試，兩個目標。** `make sim` 把測試跑在 RTL 上。`make gatesim` 把同一份 Python、scoreboard 和暫存器模型，跑在合成後的 netlist 上。這只有在 `tb/` 只碰 top-level port 時才成立。偷看內部的 monitor 會在 RTL 上過、在 gate 上死，因為 netlist 裡沒有內部名字。

**時序沒收，CI 就紅。** LibreLane 把時序違規報成 warning，所以一個設計可以跑完整條流程，卻收不了自己的時脈。CI 有一步先印出沒收到的路徑，再讓 build 失敗。

**DUT 的 bug 留在裡面。** 驗一個你不能改的設計，跟驗一個你自己寫的，是兩種不同的練習。DV 工程師領薪水做的是前者。

**多個 seed 與覆蓋率。** `make regress` 讓每個測試跑它的 seed，再量同樣那些執行的覆蓋率。覆蓋率的數字屬於生成的 Verilog，不屬於 vendored 的 SystemVerilog。

## 快速開始

你需要 Docker、Make 和 Git。用 GitHub Codespace 則一個都不用。

```bash
git clone https://github.com/anlit75/c4o-pyuvm.git
cd c4o-pyuvm
make sim          # 編譯、lint、合成、Verilog 模擬、pyuvm 測試：幾秒鐘
make gds          # 物理流程：幾分鐘，第一次還要下載好幾 GB 的 PDK
make gatesim      # 同一份測試，跑在 gate 上
```

[線上結果網頁](https://anlit75.github.io/c4o-pyuvm/)顯示這些指令的產出。

## 這個 Repo 的指令

| 指令 | 做什麼 |
|---|---|
| `make sim` | 對 RTL 跑 Verilog 煙霧測試和 pyuvm 測試 |
| `make gatesim` | 在 `make gds` 之後，對 netlist 跑同一份測試。之後 RTL 改過就會停下 |
| `make regress` | 跑 `tb/regression.yaml` 裡的測試，每個跑它的 seed，再量覆蓋率 |
| `make cocotb SEED=<n> TEST=<entry>` | 重播一個 seed 或一個測試 |
| `make ral` | 從 `regs/apb_uart.rdl` 重新生成 `tb/uart_ral.py` |
| `make sv2v` | 從 `rtl/vendor/` 重新生成 `rtl/apb_uart_sv.v` |

失敗的 `make regress` 會印出重播指令，例如 `make cocotb SEED=<n> TEST=test_uart.random_bytes`。payload 會記進 log，所以一次紅掉的 CI 會同時告訴你 seed 和那些位元組。

`make help` 列出全部指令。

## 受測設計

[pulp-platform/apb_uart_sv](https://github.com/pulp-platform/apb_uart_sv) 是一顆 16550 風格的 UART。它原封不動地 vendored 在 `rtl/vendor/`，commit 是 `dfad6e04d19cc9481d3cd2750b45b970dc61271b`（Solderpad 0.51）。它有 APB 暫存器解碼、16 byte 的 TX 和 RX FIFO、共用除頻值的序列化與解序列化、parity、FIFO trigger level 和一個中斷。

它的上游已封存。三個發現都記錄下來而不是修掉：

| 發現 | 寫在哪裡 |
|---|---|
| `fifo_tx_data` 上被推論出的 latch | `config.yaml`，lint 豁免旁邊 |
| `cfg_stop_bits_i` 在 TX 實例上被註解掉，而 RX 照 `LCR[2]` 走 | `regs/apb_uart.rdl` 的 `STB` 欄位 |
| 暫存器檔裡 8 個自我迴圈的死位元，它會讓物理流程中止 | `config.yaml`，`ERROR_ON_SYNTH_CHECKS` 旁邊 |

`rtl/apb_uart_sv.v` 是 `sv2v` 從那份 SystemVerilog 翻出來的 Verilog-2005，因為 yosys 和 Icarus 都讀不了原檔。`make sv2v` 會重新生成它，CI 會檢查它有沒有漂移。兩個生成檔都 commit 進去，所以一份新 clone 不必先跑生成器就能跑完所有東西。

## 適合誰

這個 repo 給已經在驗硬體、或正在學怎麼驗的人。它假設你看得懂 Verilog、知道合成和 netlist、也碰過某種 bus 協定。它同時假設你認得 UVM 那套詞彙。指南解釋的是這一個環境為什麼這樣搭，不是每一層各自存在的理由。

如果對你來說 Verilog 和整條流程比較新，先從 [ChipForAll](https://github.com/anlit75/ChipForAll/blob/main/README.zh-TW.md) 開始。它用一個小到可以一眼看完的設計把那些教完。如果新的是 UVM 那套詞彙，ChipForAll 補不了，因為它的測試是平的。該去的是 pyuvm 自己的文件。

## pyuvm 不是 SystemVerilog UVM

[pyuvm](https://github.com/pyuvm/pyuvm) 用 Python 實作 UVM 1.2 的類別庫。這裡的分層、phase、objection 機制和暫存器層都是真的架構。轉不過去的是語言：SystemVerilog 的 macro、factory、virtual interface 和 `fork`/`join` 都留在原地。

所以「建置過 pyuvm 驗證環境」是這個 repo 撐得起的說法。「SystemVerilog UVM 經驗」不是。如果你在做作品集，這個差別值得講清楚。一個會追問第二句的面試官會問出你指的是哪一個。

## 延伸閱讀

[指南](docs/guide.zh-TW.md)講測試平台怎麼搭的，以及為什麼：

- [環境](docs/guide.zh-TW.md#環境)：scoreboard 檢查什麼，以及它刻意不模擬什麼
- [每個測試抓什麼](docs/guide.zh-TW.md#每個測試抓什麼)：怎麼確認一個測試還會失敗
- [暫存器模型](docs/guide.zh-TW.md#暫存器模型)：SystemRDL 說不出 16550 的哪四件事，以及它需要的 pyuvm 設定
- [跑在 gate 上](docs/guide.zh-TW.md#跑在-gate-上)：讓這件事成立的那一條規則
- [時序與 constraint](docs/guide.zh-TW.md#時序與-constraint)：時脈為什麼是 90.9 MHz
- [專案結構](docs/guide.zh-TW.md#專案結構)：檔案，以及 `WAVES=1` 寫出的波形
- [設定檔參考](docs/guide.zh-TW.md#設定檔參考)

---

<div align="center">

[MIT License](LICENSE) · 由 [c4o-core](https://github.com/anlit75/c4o-core) 驅動，從 [ChipForAll](https://github.com/anlit75/ChipForAll) 模板建立

</div>
