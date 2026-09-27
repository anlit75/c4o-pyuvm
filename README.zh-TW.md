# c4o-pyuvm

![CI](https://github.com/anlit75/c4o-pyuvm/actions/workflows/verify.yml/badge.svg)
[![License](https://img.shields.io/github/license/anlit75/c4o-pyuvm)](LICENSE)

*[English](README.md)*

**一個驗別人家 UART 的 pyuvm testbench，一路做到 GDS。**

一個 APB agent、一個 scoreboard、一個從 SystemRDL 檔生成的暫存器模型 —— 對 RTL 跑一
次，再對它合成出來的 gate 跑一次。每件事一個 `make` 指令，不用裝任何東西。

這不是拿來放你自己設計的模板。[ChipForAll](https://github.com/anlit75/ChipForAll)
才是，這個 repo 是從它建出來的。

**這是給誰看的。** 給已經在驗硬體、或正在學怎麼驗的人。它假設你看得懂 Verilog、知道
合成和 netlist 是什麼、也碰過某種 bus 協定——指南直接討論 APB 的 phase 和 16550 的暫
存器圖，兩個都不會先解釋。它同時也假設你認得那套詞
彙——agent、driver、monitor、sequencer、scoreboard、`ConfigDB`、暫存器模型——而且它解
釋的是**這一個**環境為什麼這樣搭，不是那些層各自存在的理由。如果這些對你是新的，先從
[ChipForAll](https://github.com/anlit75/ChipForAll) 開始：它用一個小到可以一眼看完的
設計教完整條流程，而這個 repo 之後還會在這裡。

**pyuvm 不是 SystemVerilog UVM**，而如果你在做作品集，這個差別值得講清楚。
[pyuvm](https://github.com/pyuvm/pyuvm) 是用 Python 實作 UVM 1.2 的類別庫，所以這裡的
架構是真的：一樣的分層、一樣的 phase、一樣的 objection 機制、一樣的暫存器層。轉不過去
的是語言——SystemVerilog 的 macro、factory、virtual interface、`fork`/`join`。所以
「建置過 pyuvm 驗證環境」是這個 repo 撐得起的說法；「SystemVerilog UVM 經驗」不是，而
一個會追問第二句的面試官會問出你指的是哪一個。

## 它跟別人不一樣的地方

**Gate-level 用的是同一份測試。** 不是另寫一份給 netlist 的 testbench —— 同一份
Python、同一個 scoreboard、同一個暫存器模型：

```bash
make gds          # 產出 netlist
make cocotb-gl    # 拿同一份測試去跑它
```

這只有在 `test/` 裡沒有任何東西碰到 top-level port 以外的訊號時才成立。netlist 裡所有
內部名字都消失了，所以一個偷看內部的 monitor 會在 RTL 上過、在這裡死。

**暫存器圖只有一份。** `regs/apb_uart.rdl`。`make ral` 從它生成 pyuvm 模型，CI 會重新
生成並 diff，所以圖和模型不可能漂移。

**時序沒收，CI 就紅。** LibreLane 把時序違規報成 warning，所以一個設計可以跑完整條流程
卻收不了自己的時脈。這裡有一步把它變成 build 失敗，並先印出沒收到的路徑。

**DUT 的 bug 留在裡面。** 驗一個你不能改的設計，跟驗一個你自己寫的，是兩種不同的練
習 —— 而 DV 工程師領薪水做的是前者。

## 快速開始

```bash
git clone https://github.com/anlit75/c4o-pyuvm.git
cd c4o-pyuvm
make all          # lint、Verilog 模擬、pyuvm 測試、合成 —— 幾秒鐘
make gds          # 物理流程：幾分鐘，第一次還要抓約 3GB 的 PDK
make report       # 面積、時序、功耗、signoff
make cocotb-gl    # 同一份測試，跑在 gate 上
```

需要 Docker、Make、Git —— 或者一個都不用：用 GitHub Codespace 打開。

## 受測設計

[pulp-platform/apb_uart_sv](https://github.com/pulp-platform/apb_uart_sv)，一顆
16550 風格的 UART，原封不動 vendored 在 `src/vendor/`，commit
`dfad6e04d19cc9481d3cd2750b45b970dc61271b`（Solderpad 0.51）。APB 暫存器解碼、16 byte
的 TX/RX FIFO、共用除頻值的序列化與解序列化、parity、FIFO trigger level、一個中斷。

它的上游已封存。三個發現都記錄下來而不是修掉：

| 發現 | 寫在哪裡 |
|---|---|
| `fifo_tx_data` 上被推論出的 latch | `config.yaml`，lint 豁免旁邊 |
| `cfg_stop_bits_i` 在 TX 實例上被註解掉，而 RX 照 `LCR[2]` 走 | `regs/apb_uart.rdl` 的 `STB` 欄位 |
| 暫存器檔裡 8 個自我迴圈的死位元，它會讓物理流程中止 | `config.yaml`，`ERROR_ON_SYNTH_CHECKS` 旁邊 |

`src/apb_uart_sv.v` 是 `sv2v` 從那份 SystemVerilog 翻出來的 Verilog-2005，因為 yosys
和 Icarus 都讀不了原檔。`make rtl` 會重新生成它。

## 指令

| 指令 | 說明 | 產出 |
|---|---|---|
| `make all` | `lint`、`sim`、`cocotb`、`synth` —— 所有幾秒內跑完的東西 | 終端機 |
| `make lint` | Verilator lint | 終端機 |
| `make sim` | Verilog 煙霧測試 | `build/tb_apb_uart.vcd` |
| `make cocotb` | pyuvm 測試對 RTL | `build/cocotb-results.xml` |
| `make cocotb-gl` | 同一份測試對 netlist（要先 `make gds`） | `build/cocotb-gl-results.xml` |
| `make rtl` | 從 `src/vendor/` 重新生成 `src/apb_uart_sv.v` | `src/apb_uart_sv.v` |
| `make ral` | 從 `regs/apb_uart.rdl` 重新生成 `test/uart_ral.py` | `test/uart_ral.py` |
| `make synth` | Yosys 合成 | `build/synthesis.json` |
| `make schematic` | 把電路畫成 SVG | `build/schematic.svg` |
| `make gds` | 用 LibreLane 做物理 layout | `build/apb_uart_sv.gds` |
| `make report` | 上一次 `make gds` 的面積、時序、功耗、signoff | 終端機 |
| `make shell` | 進入 c4o-core 容器 | — |
| `make clean` | 刪掉 `build/`，保留 `runs/` | — |
| `make distclean` | 刪掉 `build/` 和 `runs/` | — |

`make cocotb SEED=<n>` 重播一次隨機失敗。payload 會記進 log，所以一次紅掉的 CI 會同時
告訴你 seed 和那些位元組。

## 專案結構

```text
config.yaml           設計名稱、時脈、constraint —— 連理由一起
regs/apb_uart.rdl     暫存器圖，以及 SystemRDL 說不出口的事
src/apb_uart_sv.v     由 make rtl 生成 —— 不要手改
src/vendor/           別人的 SystemVerilog，原封不動
test/apb_agent.py     APB3 driver、monitor、agent、暫存器 adapter
test/uart_env.py      環境、scoreboard、測試基底類別
test/uart_ral.py      由 make ral 生成 —— 不要手改
test/test_uart.py     資料路徑，走 DUT 自己的 loopback
test/test_ral.py      暫存器，透過模型
test/tb_apb_uart.v    Verilog 煙霧測試
docs/guide.zh-TW.md   它怎麼運作
```

其中兩個檔案是生成後 commit 進去的，所以一份新 clone 不必先跑生成器就能跑完所有東西。

## 下一步

[指南](docs/guide.zh-TW.md)講 testbench 怎麼搭的，以及為什麼：

*   [環境](docs/guide.zh-TW.md#環境) —— scoreboard 檢查什麼，以及它刻意不模擬什麼
*   [每個測試抓什麼](docs/guide.zh-TW.md#每個測試抓什麼) —— 以及怎麼確認一個測試還會失敗
*   [暫存器模型](docs/guide.zh-TW.md#暫存器模型) —— SystemRDL 說不出 16550 的哪四件事，以及它需要的 pyuvm 設定
*   [跑在 gate 上](docs/guide.zh-TW.md#跑在-gate-上) —— 讓這件事成立的那一條規則
*   [時序與 constraint](docs/guide.zh-TW.md#時序與-constraint) —— 時脈為什麼是 90.9 MHz
*   [設定檔參考](docs/guide.zh-TW.md#設定檔參考)

---

由 [c4o-core](https://github.com/anlit75/c4o-core) 驅動，從
[ChipForAll](https://github.com/anlit75/ChipForAll) 模板建立。
