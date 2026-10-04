# 指南

*[English](guide.md)*

testbench 怎麼搭的，以及從程式碼看不出來的那些決定。這個 repo 是什麼、怎麼跑，在
[README](../README.zh-TW.md)。

## 環境

```
test/apb_agent.py   ApbTxn、driver、monitor、agent、暫存器 adapter
test/uart_env.py    環境、scoreboard、測試基底類別
test/test_uart.py   資料路徑測試
test/test_ral.py    暫存器測試
```

**driver 不是狀態機。** APB3 只有兩個 phase，而這顆 DUT 把 `PREADY` 無條件拉高，所以沒
有 backpressure 要模擬：帶 `PSEL` 驅動位址、拉起 `PENABLE`、在結束 access phase 的那個
邊緣讀 `PRDATA`、放掉 `PSEL`。每次都是三個 cycle。monitor 盯 `PSEL`、`PENABLE`、
`PREADY` 同時成立的那個 cycle，然後把看到的廣播出去。

**scoreboard 檢查 loopback，不檢查位元時序。** `tx_o` 接回 `rx_i`，所以每個寫進 THR 的
位元組都必須照順序從 RBR 出來。這一條關係就涵蓋了 APB 解碼、兩個 FIFO、序列化和解序列
化。

改成模擬序列時序的話，等於是拿 DUT 的除頻運算去對一份自己抄的同樣運算 —— 證明不了什
麼，而且除頻值一改就壞。

scoreboard 確實會追 `LCR[7]`。位址 `0x0` 上，寫是 THR、讀是 RBR，**但只在那個位元是 0
的時候**；DLAB 設起來時同一個位址是除頻鎖存器，跟 FIFO 無關。

**loopback 是一個 coroutine。** cocotb 把 DUT 當成 root 來 elaborate，所以沒有一層
testbench module 可以在裡面把兩個 port 接起來：

```python
async def tie_tx_to_rx():
    dut.rx_i.value = dut.tx_o.value
    while True:
        await Edge(dut.tx_o)
        dut.rx_i.value = dut.tx_o.value
```

它是由 `tx_o` 變化觸發，不是由時脈。用時脈同步鏡射會讀到邊緣前的值，於是給序列線加上一
個 cycle 的延遲 —— RTL 容得下，但帶單位延遲的 netlist 未必，因為一個 bit 只有五個
cycle 寬。一條線沒有延遲。

## 每個測試抓什麼

六個測試，每個都抓得到別人抓不到的東西。

| 測試 | 只有它抓得到 |
|---|---|
| `loopback` | 一個位元組根本走不完一圈 |
| `random_bytes` | 任何需要超過一個位元組才會顯現的問題 —— 一個沒讓 RX FIFO 前進的讀取，會永遠讀到同一個「正確」的位元組 |
| `burst` | 任何需要超過一個位元組**同時在路上**的問題 —— 一次送一個永遠不會讓 FIFO 裡有兩筆，所以分不出佇列和暫存器 |
| `reset_values` | 某個暫存器 reset 出來的值是錯的 |
| `register_readback` | 一次寫到錯位址的寫入 —— 所有資料路徑測試都看不見，因為 UART 還是傳得好好的 |
| `idle_status` | 某個狀態位元錯了，但整個位元組看起來還是對的 |

`register_readback` 就是暫存器模型存在的理由。其他測試在一個把 IER 的值寫進 MCR 的設計
上全都會過。

**那張表就是這組測試的涵蓋率論證，而且是唯一的一個。** 這裡沒有 functional coverage 也
沒有 code coverage：生成的暫存器模型是用 `UVM_NO_COVERAGE` 建的，也沒有任何地方在收
coverpoint。這種規模的設計、六個測試，還可以一個一個論證，那就是那張表在做的事——而面
試官說的 coverage-driven verification，指的是「當表格不再可行時接手的那套機制」。你手上
有的是哪一種，值得先搞清楚。

### 確認一個測試還會失敗

一個從沒失敗過的測試，是一個沒人檢查過的測試。把設計弄壞、跑測試、確認你瞄準的那個會
失敗，而且訊息有用：

```bash
# 例如在 src/apb_uart_sv.v 裡讓 THR 的寫入掉一個最低位元
make cocotb                       # loopback: "sent 0xa5, RBR returned 0xa4"
git checkout -- src/apb_uart_sv.v
```

其中兩件事值得知道：

*   **`reset_values` 對 LSR 比名字聽起來弱。** `THRE` 和 `TEMT` 是組合邏輯驅動的，所以
    reset 值在第一個時脈邊緣就被蓋掉，從 bus 上觀察不到。改 RTL 裡的那個值不會讓任何測
    試失敗。那個檢查真正斷言的是「一個閒置的傳送器會說自己是空的」—— 這也是
    `idle_status` 要逐欄位釘住那些位元的原因。
*   **有一個檢查是瞄準 testbench 自己的。** 測試基底類別會斷言 scoreboard 比對到的位元
    組數目正好等於送出去的數目，所以把 monitor 弄啞會大聲失敗，而不是讓每次比對都在空
    佇列上通過。

## 暫存器模型

`regs/apb_uart.rdl` 是暫存器圖。`make ral` 對它跑 `peakrdl pyuvm`，CI 會重新生成並
diff。

這份圖描述 IER、IIR、LCR、LSR。這顆 DUT 有四件事沒辦法用 SystemRDL 表達，所以其餘部分
是直接透過 agent 驅動的：

1.  **`0x0` 上的 THR/RBR 不是暫存器。** 寫是推進 TX FIFO、讀是從 RX FIFO 彈出，沒有儲
    存可以鏡射。UVM 有 `uvm_reg_fifo` 處理這件事，PeakRDL 不生成它。
2.  **`0x2` 的 FCR 是唯寫，而且跟唯讀的 IIR 共用位址。** `alias` 是 SystemRDL 給「一個
    位址兩種視角」的機制，但它是**同一份儲存**的視角，而這兩個是不相干的硬體。
3.  **`LCR[7]` 設起來時，DLL 和 DLM 取代 THR 和 IER。** 一個暫存器的位址不能取決於另一
    個暫存器的內容。
4.  **MCR、MSR、SCR 不在圖裡。** RTL 為它們 reset 了儲存，然後從不解碼，所以讀回來都是
    0。把它們寫進圖裡只會讓模型預測設計給不出來的值。

期望的 reset 值是從 `reg.get_reset()` 來的，所以 `.rdl` 仍是暫存器圖唯一被寫下來的地
方。

### 生成的模型需要的 pyuvm 設定

PeakRDL 不會產出這些，`uart_env.py` 負責設定。碰到下面任一個錯誤，原因就在這裡：

| 錯誤 | 解法 |
|---|---|
| 任何存取都出 `unsupported operand type(s) for +: 'NoneType' and 'int'` | map 是用 `UVM_NO_ENDIAN` 建的，pyuvm 讀成「沒指定 endianness」；用一個真的 endianness 重新 configure |
| 同樣的錯誤，前面還有 `Map ... does not seem to initialized correctly` | `build()` 之後要呼叫 `lock_model()` |
| `value read from DUT (0x5F) does not match mirrored value (0x0)` | `set_auto_predict(True)` —— 否則 mirror 永遠停在 reset 值 |
| `mirror(UVM_CHECK)` 印出不符，測試卻還是過 | `set_sv_uvm_style_reporting_enabled(True)`，否則暫存器層的錯誤會進到 report server 不會算的那個 logger |

用 auto-prediction 而不是在 monitor 上掛 `uvm_reg_predictor` 是刻意的。一般來說
predictor 是更好的做法，但這裡的 monitor 也會看到圖裡描述不了的 FCR 流量，於是會把
`0x2` 上的一次 FCR 寫入餵進 IIR 的 mirror。

## 跑在 gate 上

```bash
make gds          # 寫出 runs/<tag>/final/nl/
make gatesim      # 拿同一份測試去驅動它
```

**讓它成立的規則只有一條：`test/` 裡不准碰 top-level port 以外的任何東西。** netlist
裡所有內部名字都消失了。伸手進去的話，你會在這裡發現，錯誤訊息會指名合成掉的那條線。
CI 每個 pull request 都跑它就是為了這個，而且只要幾秒。

**設計帶著 `` `timescale ``，而且必須帶。** gate-level 會把 PDK 的 cell model 跟
netlist 一起編譯，而那些 model 帶著 `1ns/1ps`；RTL 自己不帶，所以 Icarus 會用「一秒」
當精度跑它。cocotb 的 `step` 單位就是那個精度，也就是同一個時脈週期在兩次執行裡意思不
一樣。`make rtl` 會把 `` `timescale 1ns / 1ps `` 寫進生成的 Verilog 讓兩邊對齊，測試則
一律用奈秒。

同樣的道理，gate-level 讀到 X 時不要去碰 `COCOTB_RESOLVE_X`。這些測試讀的暫存器都是測
試自己寫過的、或是 reset 定義好的，所以 X 是真的壞了，而 `int()` 在它上面丟例外正是要
保留的行為。

CI 裡共用的 report 那一步比對的是兩次執行的 summary 行，而不是寫死在 workflow 裡的數字：同一份測試、同
樣的判定，兩邊都要一致。

## 時序與 constraint

`config.yaml` 裡每個值旁邊都有它的理由。其中兩個值得在這裡說明。

**`IO_DELAY_CONSTRAINT: 5`，預設是 20。** 預設會把每個時脈週期的五分之一保留給 port 上
的外部延遲 —— 對一顆 pin 要驅動封裝和板子的設計是對的，對一個 `PRDATA` 只走到同一顆
die 上 APB master 的 block 是錯的。它是百分比，所以也讓時脈週期變成很差的槓桿；required
time 是

```
週期 − clock uncertainty − IO_DELAY_CONSTRAINT × 週期
```

20% 時每多加一奈秒只拿回 0.8 ns，5% 時拿回 0.95 ns。

**`CLOCK_PERIOD: 11.0` —— 90.9 MHz，不是 100。** 用一個誠實的 port 預算，這個設計收不
了 100 MHz：從 RX FIFO 的讀指標穿過 APB 讀取 mux 到 `PRDATA` 的那條路徑塞不進去。那條
路徑大約三分之一是流程為了修 hold 插進來的延遲單元，而 hold slack 小到不能少插，所以不
是調一個 constraint 就能解決的。要到 100 MHz 只能宣稱 port 的外部延遲是零，也就是斷言
「不管是誰去 latch `PRDATA`，它自己不需要 setup time」。

`ERROR_ON_SYNTH_CHECKS` 是關掉的，因為 DUT 的暫存器檔有 8 個自我迴圈的死位元，被合成前
檢查報成邏輯迴圈。它們在最佳化之後就消失，從來沒進到 netlist。CI 有一步直接去斷言那些
報告的內容，所以**新的**迴圈還是會讓 build 失敗。

## 不重跑整條流程

floorplan 相關的參數 —— `FP_CORE_UTIL`、die 的大小、擺放 —— 不需要重做合成。用 LibreLane
自己的旗標，從 floorplan 恢復上次的執行：

```bash
make gds LIBRELANE_ARGS="--from OpenROAD.Floorplan --with-initial-state runs/apb_uart_sv_run/13-openroad-floorplan/state_in.json"
```

`--with-initial-state` 指的是那個步驟上次收到的狀態：它目錄裡的 `state_in.json`。沒有它，
LibreLane 會從已經做完的設計開始，流程會失敗。這個指令會從 `runs/` 讀上一次的執行結果，這
也是 `make clean` 不動那個目錄、而 `make distclean` 才會刪掉它的原因。

恢復後重跑的步驟會接在舊步驟後面，所以在下一次完整執行之前，執行目錄裡每個步驟都有兩份。
不加 `--from` 的 `make gds` 是完整執行，它從空的執行目錄開始。

**`CLOCK_PERIOD` 不在裡面**，而這件事在這個 repo 特別重要，因為它就是這個設計時序的關
鍵。時脈是合成的輸入，合成會依它挑元件尺寸、插 buffer，所以從 floorplan 恢復的話，你量
到的是「**舊**週期合成出來的閘，在新週期下的 timing」。[時序與 constraint](#時序與-constraint)
裡那個 90.9 MHz 就是為了這個理由、用完整重跑量出來的。

## 看電路

```bash
make schematic
```

畫出 `build/schematic.svg` —— 設計呈現成 flop、加法器、mux，帶著 RTL 給它們的名字。用瀏
覽器開，或在 VS Code 裡點開。

它不是 netlist 的圖。`make synth` 跑的是完整合成，留下幾百顆製程 cell，從來沒有人從那
裡面看懂過自己的設計。`make schematic` 停得更早，停在電路還看得出原始程式碼的地方。一秒
內跑完，所以改完東西順手跑一次不花什麼成本。

## 在容器裡工作

這個 repo 附了 [Dev Container](https://containers.dev/)。用 GitHub Codespaces 開，或在
VS Code 裡選 *Reopen in Container*，你會拿到 CI 用的同一個 image，Verilog 擴充套件都裝
好了。`Makefile` 會發現自己已經在裡面，於是直接呼叫工具，不再多包一層容器。

`make gds` 在裡面也能用 —— 容器自帶一個 Docker daemon 給 LibreLane sidecar。如果它說找
不到，重建 Dev Container。

兩件要知道的事：

*   **它以 `root` 執行。** 在 Linux host 上，它寫進 `build/` 的檔案屬於 `root`，所以從
    host 跑 `make clean` 可能要 `sudo`。改成一般使用者會弄壞 Codespaces。
*   **在 Codespace 裡要注意磁碟。** 內層 daemon 有自己的 image store，所以 LibreLane 的
    image 是重抓一份而不是共用，PDK 又是 3GB。在最小的機型上那幾乎就是整顆磁碟。

`make shell` 可以從任何終端機進到同一個 image。

## 設定檔參考

`config.yaml` 是 [LibreLane](https://github.com/librelane/librelane) 的設定檔。不屬於
LibreLane 的 key 都帶 `//` 前綴，它會忽略 —— 這就是讓同一個檔案對兩邊都有效的方法。

| Key | 說明 |
|---|---|
| `DESIGN_NAME` | 頂層模組名稱；其他所有東西都從這裡讀 |
| `VERILOG_FILES` | 可合成的原始碼。每一項都會被當成字面路徑驗證，`**` 不會展開 |
| `"//TEST_FILES"` | `make sim` 用的 Verilog testbench。可以用 glob |
| `"//COCOTB_TESTS"` | `make cocotb` 和 `make gatesim` 用的 Python testbench。只放有 `@cocotb.test()` 的檔案，`test/` 其餘檔案由它們 import |
| `"//DESCRIPTION"` | 結果網頁標題下方、以及分享連結預覽裡的一句話：這個設計是什麼 |
| `CLOCK_PORT` / `CLOCK_PERIOD` | 要約束的時脈，以及它的週期（ns） |
| `IO_DELAY_CONSTRAINT` | 保留給 port 外部延遲的週期百分比 |
| `LINTER_DISABLE_WARNINGS` | 為設計豁免的 Verilator 警告 |
| `LINTER_DISABLE_WARNINGS_BLACKBOX` | 同上，但針對 PDK 的 blackbox stub |
| `ERROR_ON_SYNTH_CHECKS` | 合成前檢查的錯誤是否中止流程 |
| `FP_SIZING` / `FP_CORE_UTIL` | die 的尺寸怎麼決定 |
| `PDK` / `STD_CELL_LIBRARY` | Sky130 及其標準元件庫。別動 |

**die 自己決定大小。** `FP_SIZING: relative` 依 `FP_CORE_UTIL`（core 該有多滿）來做
floorplan，所以設計變大會得到更大的 die，而不是「塞不進去」。繞線很緊就調低它，想要小一
點的晶片就調高。

固定 die 仍然可用：`FP_SIZING: absolute` 配 `DIE_AREA: [0, 0, w, h]`。但在 relative
模式下不要把 `DIE_AREA` 留在檔案裡 —— 流程會忽略它，可是 GDS stream-out 仍然照它畫晶片
邊界，signoff 就會在一個沒人用過的邊界上失敗。

其餘都屬於 LibreLane，完整清單見
[它的文件](https://librelane.readthedocs.io/)，這個引擎讀哪些 key 見
[c4o-core README](https://github.com/anlit75/c4o-core)。
