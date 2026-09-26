# c4o-pyuvm

![CI Status](https://github.com/anlit75/c4o-pyuvm/actions/workflows/verify.yml/badge.svg)
[![License](https://img.shields.io/github/license/anlit75/c4o-pyuvm)](LICENSE)

*[English](README.md)*

**一個驗別人家 UART 的 pyuvm 範例，一路做到 GDS。** 一套 pyuvm 環境（APB agent、
scoreboard、生成的暫存器模型）跑兩次 —— 一次對 RTL，一次對它合成出來的 2710 顆
gate —— 而且每個測試都對著它要抓的 bug 驗過。

這不是拿來放你自己設計的模板。[ChipForAll](https://github.com/anlit75/ChipForAll)
才是，這個 repo 是從它建出來的。這裡是範例本身：一個特定的設計、驗過、而且把當時的
推理留在裡面。

## 它跟別人不一樣的地方

**同一份測試會跑在 gate 上。** 不是另寫一份給 netlist 的 testbench —— 同一份
Python、同一個 scoreboard、同一個暫存器模型：

```
                        RTL              gates
reset_values          190.00 ns        190.00 ns
register_readback     200.00 ns        200.00 ns
idle_status           110.00 ns        110.00 ns
loopback              800.00 ns        800.00 ns
random_bytes        11630.00 ns      11630.00 ns
burst                8600.00 ns       8600.00 ns
                    ---------        ---------
TESTS=6 PASS=6      21530.01 ns      21530.01 ns
                       0.53 s           1.34 s（實際時間）
```

**兩邊的模擬時間完全相同。** 這只有在 `test/` 裡沒有任何東西碰內部訊號時才成立：
netlist 裡所有內部名字都消失了，所以一個偷看 `dut.regs_q` 的 monitor 會在 RTL 上過、
在 gate 上死。`make cocotb-gl` 就是你會知道的地方。

**每個測試都對著它要抓的 bug 跑過。** 不是「測試都過」—— 是把設計弄壞、看那個測試、
而且只有那個測試，失敗。表格在[指南](docs/guide.zh-TW.md#證明一個測試會失敗)裡，其中
一列正是暫存器模型存在的理由：IER 的寫入被導到錯的位址，六個資料路徑檢查全都看不見，
只有 mirror 抓得到。

**DUT 是別人的，它的 bug 留在裡面。**
[pulp-platform/apb_uart_sv](https://github.com/pulp-platform/apb_uart_sv)，原封不動
vendored 在 `dfad6e04d19cc9481d3cd2750b45b970dc61271b`，Solderpad 0.51。驗一個你不能
改的設計，跟驗一個你自己寫的，是兩種不同的練習 —— 而 DV 工程師領薪水做的是前者。三個
發現都記錄下來而不是修掉：

| 發現 | 寫在哪裡 |
|---|---|
| `fifo_tx_data` 上被推論出的 latch —— layout 裡 8 顆 `dlxtn` | `config.yaml`，lint 豁免旁邊 |
| `cfg_stop_bits_i` 在 TX 實例上被註解掉，而 RX 照 `LCR[2]` 走 | `regs/apb_uart.rdl` 的 `STB` 欄位 |
| 暫存器檔裡 8 個自我迴圈的死位元，它讓物理流程中止 | `config.yaml`，`ERROR_ON_SYNTH_CHECKS` 旁邊 |

**暫存器圖只有一份。** `regs/apb_uart.rdl`，SystemRDL 寫的；`make ral` 把它變成
pyuvm 模型，CI 會重新生成並 diff，所以兩者不可能漂移。它的檔頭大部分在講 SystemRDL
**沒辦法**描述這顆 1980 年代周邊的四件事 —— 那才是值得讀的部分。

## 快速開始

```bash
git clone https://github.com/anlit75/c4o-pyuvm.git
cd c4o-pyuvm
make all          # lint、Verilog 模擬、六個 pyuvm 測試、合成 —— 幾秒鐘
make gds          # 物理流程：約 5 分鐘，第一次還要抓約 3GB 的 PDK
make report       # 它量到了什麼
make cocotb-gl    # 同樣六個測試，跑在 make gds 剛產出的 gate 上
```

需要 Docker（Desktop 或 Engine）、Make、Git —— 或者一個都不用：用 GitHub Codespace
打開，裡面都備好了。

## 它量到什麼

`make gds` 之後 `make report`：

```
  apb_uart_sv

  die              236.605 x 247.325 um  (58518.3 um^2)
  utilization      54.2%
  standard cells   2710
  setup slack      +0.92 ns  (0 violations)
  hold slack       +0.11 ns  (0 violations)
  power            4.095 mW
  signoff          clean  (Magic DRC, KLayout DRC, LVS, antenna, XOR)
  lint warnings    8
  layout           runs/apb_uart_sv_run/final/render/apb_uart_sv.png
```

90.9 MHz，不是 100，而且這是三輪量測換來的、不是猜一次就到。
[為什麼](docs/guide.zh-TW.md#收時序花了三個錯答案)在指南裡：sky130 的預設把每個時脈
週期的五分之一保留給 port 的外部延遲，這對有 pad 的晶片是對的、對一個 block 是錯的，
而且在你注意到之前，它會讓時脈週期幾乎變成無效的槓桿。

CI 會把關。`setup slack` 或 `hold slack` 任一行不是 `(0 violations)` 就讓 build 變紅 ——
因為 LibreLane 把時序違規報成 warning，而在那一步存在之前，這個 repo 已經在一個收不了
自己時脈的設計上綠過兩次。

## 指令

| 指令 | 說明 | 產出 |
|---|---|---|
| `make all` | `lint`、`sim`、`cocotb`、`synth` —— 所有幾秒內跑完的東西。 | `終端機` |
| `make lint` | 用 Verilator 檢查生成的 Verilog。 | `終端機` |
| `make sim` | Icarus Verilog 跑的 Verilog 煙霧測試。 | `build/tb_apb_uart.vcd` |
| `make cocotb` | 六個 pyuvm 測試對 RTL。 | `build/cocotb-results.xml` |
| `make cocotb-gl` | 同樣六個對 netlist。要先 `make gds`。 | `build/cocotb-gl-results.xml` |
| `make rtl` | 從 vendored SystemVerilog 重新生成 `src/apb_uart_sv.v`。 | `src/apb_uart_sv.v` |
| `make ral` | 從 `regs/apb_uart.rdl` 重新生成 `test/uart_ral.py`。 | `test/uart_ral.py` |
| `make synth` | 用 Yosys 把 RTL 合成成 gate。 | `build/synthesis.json` |
| `make schematic` | 把電路畫成到處都能開的 SVG。 | `build/schematic.svg` |
| `make gds` | 用 LibreLane 做出物理 layout（約 5 分鐘）。 | `build/apb_uart_sv.gds` |
| `make report` | 上一次 `make gds` 的面積、時序、功耗、signoff。 | `終端機` |
| `make shell` | 進入 c4o-core 容器的 bash。 | — |
| `make gatesim` | Verilog 的 gate-level testbench。這裡沒用到 —— `cocotb-gl` 涵蓋了。 | `終端機` |
| `make clean` | 刪掉 `build/`。保留 `runs/`，`report` 和 `cocotb-gl` 要讀它。 | — |
| `make distclean` | 刪掉 `build/` 和 `runs/`。 | — |

`make help` 會在終端機列出來。`make cocotb SEED=<n>` 重播一次隨機失敗 —— payload 會記
進 log，所以一次紅掉的 CI 會同時告訴你 seed 和那些位元組。

## 專案結構

```text
.
├── config.yaml        # ⚙️ 設計名稱、時脈、constraint —— 連理由一起
├── Makefile           # 🎮 指令中心
├── regs/
│   └── apb_uart.rdl   # 📋 暫存器圖，以及 SystemRDL 說不出口的事
├── src/
│   ├── apb_uart_sv.v  # 🤖 由 make rtl 生成 —— 不要手改
│   └── vendor/        # 📦 別人的 SystemVerilog，原封不動
├── test/
│   ├── apb_agent.py   # 🚌 APB3 driver、monitor、agent、暫存器 adapter
│   ├── uart_env.py    # 🏗️ 環境、scoreboard、測試基底類別
│   ├── uart_ral.py    # 🤖 由 make ral 生成 —— 不要手改
│   ├── test_uart.py   # 🧪 資料路徑，走 DUT 自己的 loopback
│   ├── test_ral.py    # 🧪 暫存器，透過模型
│   └── tb_apb_uart.v  # 🧪 Verilog 煙霧測試（make sim）
└── docs/guide.zh-TW.md # 📚 它怎麼運作，以及路上出過什麼錯
```

裡面有兩個檔案是生成後 commit 進去的：`src/apb_uart_sv.v` 和 `test/uart_ral.py`。把
生成的程式碼 commit 進來換到的是「一份新 clone 就能跑完所有東西」，代價是那一對可能
漂移 —— 所以 CI 會重新生成 `test/uart_ral.py` 並 diff。

## 下一步

[指南](docs/guide.zh-TW.md)是有推理在裡面的那部分：

*   [環境](docs/guide.zh-TW.md#環境) —— agent、scoreboard，以及 scoreboard 為什麼從不看序列線
*   [證明一個測試會失敗](docs/guide.zh-TW.md#證明一個測試會失敗) —— mutation 表格，以及每一列是哪個測試抓到的
*   [暫存器模型](docs/guide.zh-TW.md#暫存器模型) —— SystemRDL 的四個極限，以及 pyuvm 需要而 PeakRDL 不給的四件事
*   [跑在 gate 上](docs/guide.zh-TW.md#跑在-gate-上) —— 它抓到了什麼，第一個是 testbench 對時間的理解有 bug
*   [收時序花了三個錯答案](docs/guide.zh-TW.md#收時序花了三個錯答案) —— 其中兩個是量測過才丟掉的

---

由 **[c4o-core](https://github.com/anlit75/c4o-core)** 引擎驅動，從
**[ChipForAll](https://github.com/anlit75/ChipForAll)** 模板建立。
