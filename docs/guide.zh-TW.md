# 指南

*[English](guide.md)*

這個 repo 的驗證怎麼運作，以及做到這裡的路上出過什麼錯。[README](../README.zh-TW.md)
講的是「它是什麼、怎麼跑」；這份講的是「它為什麼長這樣」。

## 環境

四個手寫的檔案、623 行、一個想法：只透過 DUT 的 pin 驅動它，別的都不碰。

```
test/apb_agent.py   143  ApbTxn、driver、monitor、agent，以及暫存器 adapter
test/uart_env.py    197  環境、scoreboard、測試基底類別
test/test_uart.py   137  資料路徑的測試
test/test_ral.py    146  暫存器的測試
test/uart_ral.py    150  由 make ral 生成
```

**driver 不是狀態機。** APB3 只有兩個 phase，而這顆 DUT 無條件把 `PREADY` 拉高
（`assign PREADY = 1'b1`），所以沒有 backpressure 要模型化：setup、access、在結束
access phase 的那個邊緣讀 `PRDATA`、放掉 `PSEL`。每次都三個 cycle。monitor 是同一件事
從另一側看 —— 它等 `PSEL`、`PENABLE`、`PREADY` 同時為 1 的那個 cycle，然後把看到的廣播
出去。

**scoreboard 從不看序列線。** `tx_o` 接回 `rx_i`，所以每個寫進 THR 的位元組都必須照
順序從 RBR 出來。這一條關係就涵蓋了 APB 解碼、TX FIFO、序列化器、解序列化器和 RX
FIFO。改成模型化 bit timing 的話，等於拿 DUT 的除頻運算去對照同一套運算的第二份拷貝 ——
什麼都沒證明，而且除頻一改就壞。

它確實得追蹤暫存器的寫入。在 offset `0x0`，寫是 THR、讀是 RBR，但**只在 `LCR[7]` 為 0
的時候**：DLAB 設起來時同一個位址是除頻鎖存器，跟 FIFO 毫無關係。scoreboard 追那一個
位元，才知道哪些讀是資料。

**loopback 是 coroutine，不是一條線。**

```python
async def tie_tx_to_rx():
    dut.rx_i.value = dut.tx_o.value
    while True:
        await Edge(dut.tx_o)
        dut.rx_i.value = dut.tx_o.value
```

cocotb 把 DUT 當 root elaborate —— 沒有 testbench module 可以做這個接線 —— 所以由 Python
做。結果這反而是比較好的答案：它在 netlist 上行為完全一樣，而 Verilog wrapper 在那裡根本
不存在。

它是由 `tx_o` 變化驅動的，不是由時脈驅動，而這是修正而不是初稿。clocked mirror 讀到的是
`tx_o` 邊緣前的值，等於在序列線上多加一個 cycle 的延遲。RTL 容得下；netlist 用
`-DUNIT_DELAY` 編、每顆 cell 都要一步，餘裕更少 —— 一個 bit 只有 `DIVISOR + 1` = 5 個
cycle 寬。

## 證明一個測試會失敗

一個從來沒失敗過的測試，是一個沒人檢查過的測試。這裡每個測試都對著一個故意弄壞的設計跑
過，而重點不是它們全都變紅 —— 是**哪些**變紅。

六個對 DUT 的 mutation，每個套上、用 `RANDOM_SEED=4242` 跑、再還原：

| mutation | `reset_values` | `register_readback` | `idle_status` | `loopback` | `random_bytes` | `burst` |
|---|---|---|---|---|---|---|
| IIR reset 成 `0b0000` | **FAIL** | PASS | PASS | PASS | PASS | PASS |
| LSR reset 成 `0x00` | PASS | PASS | PASS | PASS | PASS | PASS |
| LCR 寫入掉最低位 | PASS | **FAIL** | PASS | FAIL | FAIL | FAIL |
| IER 寫入落到 MCR | PASS | **FAIL** | PASS | PASS | PASS | PASS |
| `LSR.THRE` 永不拉起 | FAIL | PASS | **FAIL** | PASS | PASS | PASS |
| `LSR.TEMT` 永不拉起 | FAIL | PASS | **FAIL** | PASS | PASS | PASS |

以及另外五個瞄準資料路徑的：

| mutation | `loopback` | `random_bytes` | `burst` |
|---|---|---|---|
| THR 寫入掉最低位 | FAIL | FAIL | FAIL |
| `LSR[0]`（data ready）綁 0 | FAIL | FAIL | FAIL |
| RBR 讀取不 pop RX FIFO | **PASS** | FAIL | FAIL |
| TX FIFO 只裝一個位元組，不是十六個 | **PASS** | **PASS** | FAIL |
| monitor 不回報任何 transfer | FAIL | FAIL | FAIL |

要看的是欄，不是列。每個粗體的 **PASS** 都是一個看不見那個 bug 的測試，也因此正是下一個
測試存在的理由：

*   **一個位元組分不出 queue 和 register。** `loopback` 送 `0xA5` 再讀回來；RX FIFO
    永不 pop 的時候，它讀到的還是那個正確的位元組。`random_bytes` 送二十個，在第二個
    就失敗。
*   **一次送一個位元組，永遠不會讓 FIFO 裡同時有兩個。** 只有 `burst`（十六個全寫完才
    開始讀）看得見深度變成 1。
*   **值對、位址錯，資料路徑完全看不見。** IER 的寫入被導到 MCR，UART 送出去的東西一點
    都沒變。mirror 抓到了：`Register 'regs.IER' value read from DUT (0x0) does not
    match mirrored value (0x5)`。那一列就是「為什麼要有暫存器模型」的論證。
*   **有一個 mutation 瞄的是 testbench，不是 DUT。** monitor 被靜音時，每個 scoreboard
    檢查都會在空 queue 上通過 —— 所以測試基底類別改成斷言數量：`the scoreboard matched
    0 bytes through the loopback, not 1`。

**而且有一個 mutation 活下來。** 把 LSR 的 reset 從 `0x60` 改成 `0x00`，什麼都沒壞，
因為那個 reset 值從 bus 上觀測不到：`THRE` 和 `TEMT` 是由 `tx_elements` 和 `tx_ready`
組合邏輯驅動的，`regs_n` 在 reset 後第一個時脈邊緣就把兩者都蓋掉。`ResetValuesTest` 的
docstring 直接這麼寫，而不是假裝沒事，而 `IdleStatusTest` 改成逐欄位釘住同兩個位元 ——
這也是第一張表最後兩列有一欄會 FAIL 的原因。

## 暫存器模型

`regs/apb_uart.rdl` 是用 SystemRDL 寫的暫存器圖。`make ral` 對它跑 `peakrdl pyuvm`，而
CI 會重新生成並 diff，所以測試驅動的模型和暫存器圖的描述不可能漂移。

`.rdl` 描述了 IER、IIR、LCR、LSR。它的檔頭大部分在講它**沒辦法**描述的東西，而那正是
「把暫存器描述語言拿去對付 1980 年代周邊」有意思的地方：

1.  **`0x0` 的 THR/RBR 不是暫存器。** 寫進 TX FIFO、讀出 RX FIFO。沒有 storage 可以
    mirror —— 寫 `0xA5`，下一次讀回來的是序列線送到的東西。UVM 有 `uvm_reg_fifo` 處理
    這種情況；PeakRDL 不生成它。
2.  **`0x2` 的 FCR 唯寫，而且和唯讀的 IIR 共用位址。** SystemRDL 的 `alias` 就是給
    「一個位址兩個視角」用的機制 —— 但它是*同一份 storage* 的視角，而這兩個是無關的
    硬體：

    ```
    error: Alias register 'FCR' contains field 'TX_CLR' that does not exist in
    the primary register.
    ```
3.  **`LCR[7]` 設起來時，DLL 和 DLM 取代 THR 和 IER。** 一個暫存器的位址不能取決於另一
    個暫存器的內容。
4.  **MCR、MSR、SCR 是故意不寫的。** RTL reset 了它們的 storage，然後永遠不解碼讀或寫，
    所以它們從 default 分支讀回 0。把它們描述成暫存器會讓模型去預測設計根本回不出來的值。

`test_uart.py` 直接用 agent 驅動這四個，而且有寫明。

### pyuvm 需要而 PeakRDL 不給的四件事

每一件都是踩到失敗才找出來的，而且都寫在修它的那一行旁邊：

| | 沒有它會怎樣 |
|---|---|
| 把 map 改設成 little-endian | PeakRDL 用 `UVM_NO_ENDIAN` 建它；pyuvm 讀成「沒指定 endianness」，走進 `_get_physical_addresses_to_map` 的錯誤分支，然後每次存取都死在 `TypeError: unsupported operand type(s) for +: 'NoneType' and 'int'` |
| `lock_model()` | 一樣的失敗，前面多一句 `Map 'regs.reg_map' does not seem to initialized correctly` |
| `set_auto_predict(True)` | mirror 永遠停在 reset 值：`Register 'regs.LCR' value read from DUT (0x5F) does not match mirrored value (0x0)` |
| `set_sv_uvm_style_reporting_enabled(True)` | 暫存器層的錯誤會送到一個叫 `RegModel` 的普通 `logging` logger，report server 從不計數，所以 `mirror(UVM_CHECK)` 記了 mismatch 而**測試照樣通過** |

關於第三件：把 `uvm_reg_predictor` 掛在 monitor 上，一般來說是更好的做法 —— 它能抓到不是
暫存器層發起的寫入 —— 但在*這裡*是錯的。monitor 也看得到那些 map 故意不描述的 FCR
流量，而 predictor 會把 `0x2` 的 FCR 寫入餵進 IIR 的 mirror，因為 map 在那個位址上放的是
IIR。

模型檢查的那些 reset 值不是誰猜得出來的，而且來自不同機制：

```
IER reads 0x00, .rdl says 0x00
IIR reads 0xc1, .rdl says 0xc1     <- 讀取路徑上硬接的 0b1100 疊在 iir_q 上，而它 reset 成 0b0001
LCR reads 0x00, .rdl says 0x00
LSR reads 0x60, .rdl says 0x60
```

期望值來自 `reg.get_reset()`，不是測試裡寫的數字，所以 `.rdl` 仍然是暫存器圖唯一被寫下來
的地方。

## 跑在 gate 上

```bash
make gds          # 產出 runs/<tag>/final/nl/apb_uart_sv.nl.v
make cocotb-gl    # 用同樣六個測試驅動它
```

不是第二份 testbench。同一份 Python、同一個 scoreboard、同一個暫存器模型，對著 netlist
和 PDK 自己的 cell model 跑。一般的做法是另寫一份 gate-level testbench —— 那就是
`make gatesim` 要的東西，也是 `config.yaml` 裡沒有 `//GATE_TESTS` 的原因：第二份
testbench 就是第二個要跟第一個保持同步的 scoreboard，而它們一漂移，gate-level 那份就不
再代表任何事。

它能成立只因為 `test/` 裡沒有任何東西碰除了 top-level port 以外的東西。碰了就會在這裡
知道，以一個指名被合成拿掉的 net 的 `AttributeError`。CI 因此在每個 PR 都跑它，而它只花
三秒。

**它抓到的第一件事是 testbench 的 bug，不是設計的。** 第一次 gate-level 跑在 0.06 ns
模擬時間就掛了，三個測試全掛 —— 暫存器測試是後來才有的：

```
txn.rdata = int(self.dut.PRDATA.value)
ValueError: Unresolvable bit in binary string: 'x'. Set the COCOTB_RESOLVE_X
environment variable to configure how special values are resolved.
```

gate-level 會把 PDK 的 cell model 和 netlist 一起編進去，而 `sky130_fd_sc_hd.v` 帶著
`` `timescale 1ns/1ps ``。生成的 RTL 完全沒有 timescale，所以 Icarus 用「一秒」當精度 ——
而 cocotb 的 `step` 單位**就是**那個精度。測試要的兩步時鐘，在 **gate 上是 2 ps、在 RTL
上是 2 s**。2 ps 的時鐘配上每顆 cell 1 ns 延遲，設計根本出不了 reset，它驅動的一切都是 X。

`make rtl` 現在會把 `` `timescale 1ns / 1ps `` 寫進生成的 Verilog，測試改成要求 10 ns。

**誘人的錯解就寫在錯誤訊息裡。** `COCOTB_RESOLVE_X` 會把那個 X 變成 0，讓每個測試都在一
個根本沒在跑的設計上通過。這裡讀的都是測試自己寫過、或 reset 有定義的暫存器，所以
`PRDATA` 出現 X 就是 bug，`int()` 該炸就是該保留的行為。

另寫一份 gate-level testbench 會有它自己的 `` `timescale ``、而且從來不跟另一份比較，所以
永遠不會有任何東西指出這個不一致。這就是「一份 testbench 勝過兩份」的論證，而且沒人會事先
拿這個當理由。

**這一步斷言的**是兩次跑的結果一致：

```
RTL:   TESTS=6 PASS=6 FAIL=0 SKIP=0
gates: TESTS=6 PASS=6 FAIL=0 SKIP=0
```

兩行一樣，不是一個寫死的數字 —— 那個數字曾經寫死成 3，然後在三個全部通過的新測試上變紅。

## 收時序花了三個錯答案

flow 把 setup 違規報成 **warning**，所以這個 repo 在一個收不了自己時脈的設計上綠過兩次：

```
setup slack      -0.75 ns  (24 violations)
hold slack       +0.11 ns  (0 violations)
signoff          clean  (Magic DRC, KLayout DRC, LVS, antenna, XOR)
```

那 24 條違規的終點**全部都是 port**：

```
Startpoint: uart_rx_fifo_i.pointer_out[1] (rising edge-triggered flip-flop)
Endpoint: PRDATA[4] (out)
                             8.502929   data arrival time
               10.000000    10.000000   clock CLK (rise edge)
               -0.250000     9.750000   clock uncertainty
               -2.000000     7.750000   output external delay
                             7.750000   data required time
                            -0.752928   slack (VIOLATED)
```

`IO_DELAY_CONSTRAINT` 在 sky130 預設是 20 —— 每個時脈週期的五分之一保留給 port 的外部
延遲，10 ns 裡的 2 ns。這對 pin 要驅動封裝和板子的設計是對的。這顆是 block：`PRDATA`
走到同一顆 die 上的 APB master。它在為一塊不存在的板子付 2 ns。

五輪，每輪都是完整的 flow：

| `CLOCK_PERIOD` | `IO_DELAY_CONSTRAINT` | setup slack | violations |
|---|---|---|---|
| 10.0 | 20 | -0.75 ns | 24 |
| **11.0** | 20 | -0.70 ns | 24 |
| 10.0 | **5** | -0.03 ns | 1 |
| 10.0 | 5 | + resizer margin 0.1 —— *跟上一列到 ps 完全相同* | 1 |
| **11.0** | **5** | **+0.92 ns** | **0** |

**第二列是陷阱。** 放鬆時脈週期每一奈秒只還回 0.8 ns，因為 I/O 預算是百分比，加的每一
奈秒它都拿走五分之一。最明顯的槓桿看起來壞了 —— 而它其實就是對的槓桿，前提是預算從 20
變成 5。`required = 0.95 × period − 0.25`，而不是 `0.8 × period − 0.25`。

**第四列是把巧合當成因果。** 剩下的 slack 是 `-0.025290`，而
`GRT_RESIZER_SETUP_SLACK_MARGIN` 的預設是 `0.025`，讀起來很像「resizer 停在它的 margin，
然後 detailed routing 把它花掉」。把 margin 調到 0.1，arrival、cell 數、功耗**一點都沒
變**。resizer 不是提早停下來；它根本改不動那條路徑。

關於那條路徑值得知道的一件事：它 9.28 ns 裡有 2.83 ns 是 flow 為了修 **hold** 插進去的三
顆 `clkdlybuf4s25`。setup 關鍵路徑將近三分之一是為了解決相反問題加的 padding，而 hold
slack 只有 +0.10 ns，沒有空間少插一點。那才是這個設計真正的餘裕，而且不是改一個
constraint 能拿到的。

所以：90.9 MHz 配一個誠實的 0.55 ns port 預算，而不是 100 MHz 配一個等於零的 port 預算 ——
後者是靠宣稱「不管是誰栓住 `PRDATA`，它都不需要自己的 setup time」在紙上收掉的。兩個數字、
兩個繞路，都寫進 `config.yaml` 它們各自對應的值旁邊，因為一份只記答案的 config 會讓下一
個人重走同樣三輪。

而且現在 CI 會把關。`setup slack` 或 `hold slack` 報出任何不是 `(0 violations)` 的東西
就讓 build 失敗，而且排在印出違規路徑那一步之後 —— 所以失敗會連著證據一起來。

## 不重跑整個 flow 的迭代方式

第一次 `make gds` 大約五分鐘。之後你改的大部分東西 —— `FP_CORE_UTIL`、`CLOCK_PERIOD`、
floorplan —— 都不需要重做合成，所以把「接續上一次 run」的旗標交給 LibreLane：

```bash
make gds LIBRELANE_ARGS="--last-run --from floorplan"
```

它會從 `runs/` 讀上一次的 run，這也是為什麼 `make clean` 不動那個目錄，而
`make distclean` 才是刪它的那個。

## 看見電路

```bash
make schematic
```

畫出 `build/schematic.svg` —— 你的設計以 flop、加法器、mux 的樣子呈現，帶著 RTL 給它們的
名字。用瀏覽器開，或在 VS Code 裡點開；它是 SVG，不需要任何特別的東西就能讀。

它不是 netlist 的圖。`make synth` 跑完整合成，留下數百顆 technology cell，從那裡沒有人
學到過任何關於自己設計的事。`make schematic` 停得更早，停在電路還看得出是哪段程式碼的
地方。

不到一秒，所以每改一次都跑一下也不花什麼 —— 跟 `make gds` 不一樣。

## 在容器裡工作

這個 repo 附了一份 [Dev Container](https://containers.dev/)。用 GitHub Codespaces 開，或
在 VS Code 裡 *Reopen in Container*，你就拿到 CI 用的同一個 image，Verilog 擴充套件也裝
好了。`Makefile` 會發現自己已經在容器裡，直接呼叫工具而不是再套一層。

`make gds` 在裡面也能用：容器自己帶了一個 Docker daemon 給 LibreLane sidecar。如果
`make gds` 說找不到 daemon，重建 Dev Container —— 它要的就是這個。

兩件要知道的事：

*   **它以 `root` 執行。** 在 Linux host 上這意味著它寫進 `build/` 的檔案會歸 `root`，
    所以從 host 跑 `make clean` 可能需要 `sudo`。改成普通使用者會弄壞 Codespaces。
*   **在 Codespace 裡注意磁碟。** 內層 daemon 有自己的 image store，所以 LibreLane 的
    image 會被再抓一次而不是跟 host 共用，Sky130 PDK 又是另外 3GB。在最小的 Codespace
    機型上那幾乎是整顆磁碟 —— 選大一點的，或者從自己的 host 跑 `make gds`。

想留在自己的編輯器裡？`make shell` 會從任何終端機把你丟進同一個 image。

## 設定參考

`config.yaml` 是一份 [LibreLane](https://github.com/librelane/librelane) 設定檔。不屬於
LibreLane 的 key 帶 `//` 前綴，它會直接忽略 —— 這就是讓一個檔案同時對兩個工具都有效的
方法。

| Key | 作用 |
|---|---|
| `DESIGN_NAME` | 頂層 module 的名字。其他所有東西都從這裡讀。 |
| `VERILOG_FILES` | 可合成的來源 —— 這裡就是 `make rtl` 生成的那一個檔案。LibreLane 把每一項當字面路徑驗證，不會展開 `**`。 |
| `"//TEST_FILES"` | 給 `make sim` 的 Verilog testbench。可以用 glob。 |
| `"//COCOTB_TESTS"` | 給 `make cocotb` 和 `make cocotb-gl` 的 Python testbench。只有定義 `@cocotb.test()` 的檔案放這裡；`test/` 其他檔案由它們 import。 |
| `CLOCK_PORT` / `CLOCK_PERIOD` | 要約束的時脈，和它的週期（ns）。 |
| `IO_DELAY_CONSTRAINT` | 週期的多少百分比保留給 port 的外部延遲。這裡是 5，預設是 20 —— 見上文。 |
| `LINTER_DISABLE_WARNINGS` | 為設計豁免的 Verilator 警告。這裡有兩個，各自旁邊都寫了理由。 |
| `LINTER_DISABLE_WARNINGS_BLACKBOX` | 同樣的東西，給 PDK 那些自己沒有 timescale 的 blackbox stub。 |
| `ERROR_ON_SYNTH_CHECKS` | 這裡關掉，為了 DUT 暫存器檔裡八個自我迴圈的死位元。CI 改成直接斷言那些報告。 |
| `FP_SIZING` / `FP_CORE_UTIL` | die 怎麼定大小 —— 見下文。 |
| `PDK` / `STD_CELL_LIBRARY` | Sky130 和它的標準元件庫。別動。 |

**die 會自己決定大小。** `FP_SIZING: relative` 依 `FP_CORE_UTIL` 做 floorplan —— core
該多滿，這裡是 40%，最後出來 54.2% —— 所以比較大的設計會拿到比較大的 die，而不是「放不
下」。繞線緊就調低，想要小一點的晶片就調高。

固定 die 還是可以用：設 `FP_SIZING: absolute` 再加 `DIE_AREA: [0, 0, w, h]`。不要在
relative 模式下把 `DIE_AREA` 留在檔案裡 —— flow 已經不讀它了，但 GDS stream-out 還是會
用它畫晶片邊界，然後 signoff 就會在一個其他人都沒用到的邊界上失敗。

檔案裡其他東西都屬於 LibreLane；完整清單見
[它的文件](https://librelane.readthedocs.io/)，這個引擎讀哪些見
[c4o-core README](https://github.com/anlit75/c4o-core)。
