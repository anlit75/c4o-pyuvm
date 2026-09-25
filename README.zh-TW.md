# ChipForAll (C4O)

![CI Status](https://github.com/anlit75/ChipForAll/actions/workflows/verify.yml/badge.svg)
![release Version](https://img.shields.io/github/v/release/anlit75/ChipForAll?label=version)
[![License](https://img.shields.io/github/license/anlit75/ChipForAll)](LICENSE)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/anlit75/ChipForAll)

*[English](README.md)*

**開源晶片的驗證與 CI 起手式。** 模擬你的 RTL、用 Python 驅動它、模擬它合成出來的閘級電路、讀懂 signoff 數字——實體流程交給 LibreLane。每件事一個 `make` 指令，什麼都不用裝。

## ✨ 特色

* **🧪 真的會失敗的測試平台**：`make sim` 寫 Verilog，`make cocotb` 寫 Python。兩者該紅的時候都會回傳非零——在壞掉的設計上還會通過的測試，比沒有測試更糟。
* **🔬 閘級模擬**：`make gatesim` 拿你的測試去跑合成真正產出的 netlist。latch 推導、reset 處理都卡在 RTL 和那些閘之間，從 RTL 完全看不出來。
* **📊 看得懂的 signoff**：`make report` 從沒人會打開的 300 個 key 的 `metrics.json` 裡，挑出真正要看的幾個數字——面積、時序、功耗、DRC/LVS/antenna。
* **✅ CI 全部都跑**：一份 GitHub Actions 工作流，每次 push 都 lint、模擬、合成、產 GDS、再重跑閘級模擬。
* **🐳 什麼都不用裝**：Docker，或 Dev Container / Codespace。`make gds` 三種都能跑。

### 這個專案不是什麼

實體流程——RTL 到 GDSII——是 [LibreLane](https://github.com/librelane/librelane) 的，`make gds` 只是薄薄一層包裝。如果你只想要一份 layout，LibreLane 用 `--dockerized` 就能單獨跑，你不需要這個專案。

LibreLane 沒有涵蓋的是**模擬與驗證**。那才是這個起手式加上去的東西，外加跑它們的 CI 和 Dev Container。

## 🚀 快速啟動

### 前置作業
* Docker (Desktop 或 Engine)
* Make
* Git

*……或者以上都不需要：用 GitHub Codespace 打開，一切都已經就緒。*

### 1. 做一份自己的副本

這個儲存庫是 **GitHub 範本（template）**。按 **Use this template → Create a new repository**，然後 clone 你自己的副本：

```bash
git clone https://github.com/<你>/<你的儲存庫>.git
cd <你的儲存庫>
```

### 2. 執行完整流程

```bash
make gds
```

*第一次執行會安裝 Sky130 PDK（約 3GB），需要幾分鐘：合成、佈局繞線，然後產出版圖。*

### 3. 換成你自己的設計

範例是一個 blinky——時脈除頻器。要換成你自己的設計，有四個地方必須互相對上，其他都不用動：

| 要改的 | 在哪裡 |
|---|---|
| 你的 RTL | `src/`，列在 `config.yaml` 的 `VERILOG_FILES` |
| `DESIGN_NAME` | `config.yaml`——必須和你的頂層模組同名 |
| 你的測試平台 | `test/`，列在 `"//TEST_FILES"` 和 `"//COCOTB_TESTS"` |
| 閘級測試平台 | `test/gate/`，列在 `"//GATE_TESTS"` |

沒有別的地方寫死設計名稱：`Makefile` 和 CI 工作流都從 `config.yaml` 讀 `DESIGN_NAME`。

**最後兩列是選用的。** 把 `"//COCOTB_TESTS"` 或 `"//GATE_TESTS"` 從 `config.yaml` 刪掉，CI 就會跳過那一類測試而不是失敗。但如果把 key 留著卻指向不存在的檔案，CI 還是會失敗——這是對的，你要求了不存在的測試。

第一列弄錯的話，你會立刻知道，而不是等到 `make gds` 跑了三分鐘之後：

```console
[ERROR] DESIGN_NAME is 'my_cpu', but no module by that name is declared in
        VERILOG_FILES. Declared there: blinky.
```

## 📖 指令

| 指令 | 說明 | 輸出 |
|---|---|---|
| `make all` | `lint`、`sim`、`cocotb`、`synth`——幾秒內跑完的全部。 | `終端機` |
| `make lint` | 用 Verilator 檢查 Verilog。 | `終端機` |
| `make sim` | 用 Icarus Verilog 跑 Verilog 測試平台。 | `build/wave.vcd` |
| `make cocotb` | 執行 Python (cocotb) 測試平台。 | `build/cocotb-results.xml` |
| `make synth` | 用 Yosys 把 RTL 合成成閘級電路。 | `build/synthesis.json` |
| `make schematic` | 把電路畫成到處都開得了的 SVG。 | `build/schematic.svg` |
| `make gds` | 用 LibreLane 產生實體版圖（約 3 分鐘）。 | `build/<DESIGN_NAME>.gds` |
| `make gatesim` | 對合成後的 netlist 重跑模擬，需先執行 `make gds`。 | `終端機` |
| `make report` | 顯示上次 `make gds` 的面積、時序、功耗與 signoff。 | `終端機` |
| `make shell` | 進入 c4o-core 容器的互動式 shell。 | — |
| `make clean` | 清除 `build/`。保留 `runs/`，`report` 和 `gatesim` 要讀它。 | — |
| `make distclean` | 清除 `build/` 和 `runs/`。 | — |

`make help` 會在終端機列出這些指令。

## 📊 看懂執行結果

`make gds` 結束時會直接印出這次流程量到的數字，不必自己去翻檔案：

```
  blinky

  die              69.485 x 80.205 um  (5573.04 um^2)
  utilization      57.1%
  standard cells   198
  setup slack      +4.70 ns  (0 violations)
  hold slack       +0.11 ns  (0 violations)
  power            0.290 mW
  signoff          clean  (Magic DRC, KLayout DRC, LVS, antenna, XOR)
  lint warnings    0
  layout           runs/blinky_run/final/render/blinky.png
```

**`signoff`** 是那一列沒人會說的話：你的版圖通過了可製造性檢查。LibreLane 預設對每一項都會直接讓流程失敗，所以能跑到這一行就代表都過了——`clean` 只是把它講出來，並列出它實際看到哪幾項。有問題的時候它會改成指名道姓：`2 Magic DRC, 1 LVS`。

**`layout`** 是流程幫你的晶片畫的 PNG。打開來看看。

**slack 為正值**代表設計滿足 `config.yaml` 裡設定的時脈；負值代表沒滿足，而流程不會因此停下來——所以一次成功結束的執行，仍然可能正在告訴你它沒達標。[該怎麼辦](docs/guide.zh-TW.md#slack-為負值的時候)寫在指南裡。

單獨執行 `make report` 可以再看一次，不必重跑流程。

## 📚 接下來

[使用指南](docs/guide.zh-TW.md)涵蓋第一次執行之後的事：

* [幫你自己的設計寫測試平台](docs/guide.zh-TW.md#幫你自己的設計寫測試平台)——能真的失敗的最小骨架
* 測試變紅的時候[去看波形](docs/guide.zh-TW.md#測試失敗的時候去看波形)
* 用 [Python 寫測試平台](docs/guide.zh-TW.md#用-python-寫測試平台)、[隨機刺激對參考模型](docs/guide.zh-TW.md#隨機刺激與參考模型)，以及[閘級模擬](docs/guide.zh-TW.md#模擬閘級電路而不只是-rtl)
* [不重跑整條流程的迭代方式](docs/guide.zh-TW.md#不重跑整條流程的迭代方式)，以及[看看電路長什麼樣](docs/guide.zh-TW.md#看看電路長什麼樣)
* [在容器內開發](docs/guide.zh-TW.md#在容器內開發)，以及[完整的設定參考](docs/guide.zh-TW.md#設定參考)

## 📂 專案架構

```text
.
├── .devcontainer/     # 🐳 VS Code Dev Container 定義
├── config.yaml        # ⚙️ 設計名稱、時脈、floorplan
├── Makefile           # 🎮 指令控制中心
├── docs/              # 📚 第一次執行之後的所有事
├── src/               # ✍️ 您的 Verilog
│   └── blinky.v
├── test/              # 🧪 您的測試平台 (Testbenches)
│   ├── tb_blinky.v              # RTL 模擬 (make sim)
│   ├── test_blinky_cocotb.py    # Python 測試平台 (make cocotb)
│   ├── test_blinky_random.py    # 隨機刺激對參考模型
│   └── gate/                    # 閘級模擬 (make gatesim)
│       └── tb_blinky_gl.v
└── build/             # 📦 所有產出的檔案 (GDS, Logs, Netlists)
```

## 📝 配置設定

`config.yaml` 是一份 [LibreLane](https://github.com/librelane/librelane) 配置檔——同一個檔案同時驅動模擬與實體設計流程。以下是你通常會改的 key：

```yaml
DESIGN_NAME: my_design

VERILOG_FILES:
  - dir::src/my_design.v

# 僅供模擬使用。LibreLane 會忽略以 '//' 開頭的 key。
"//TEST_FILES":
  - dir::test/*.v

CLOCK_PORT: clk
CLOCK_PERIOD: 10.0
```

其餘的 key（`PDK`、`FP_SIZING`、`FP_CORE_UTIL`…）用於設定實體設計流程，在需要之前請保持原樣。晶片尺寸不需要你自己決定——`FP_SIZING: relative` 會把 die 長到剛好放得下你的設計。細節見[設定參考](docs/guide.zh-TW.md#設定參考)。

---

由 **[c4o-core](https://github.com/anlit75/c4o-core)** 引擎驅動。
