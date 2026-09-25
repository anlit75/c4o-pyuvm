# 使用指南

第一次執行之後的所有事。還沒跑過 `make gds` 的話，請先看 [README](../README.zh-TW.md)。

*[English](guide.md)*

## slack 為負值的時候

負 slack 代表設計沒有滿足 `config.yaml` 裡的時脈，而答案只有兩種。給設計更多時間——把 `CLOCK_PERIOD` 調大，重跑 `make gds`——或者把慢的那條路徑縮短，插 pipeline 或把邏輯搬出去。哪一種才對，取決於那個時脈速度是需求還是隨手填的；第一個設計通常是隨手填的。

想知道*哪裡*慢，讀流程已經寫好的時序報告：

```bash
cat runs/*/final/*.rpt          # 或到 runs/<tag>/ 底下找 STA 那幾步
```

最差路徑會連同上面經過的每一個閘一起列出來，時間就花在那裡。

## 幫你自己的設計寫測試平台

`test/tb_blinky.v` 是一份完整的範例，讀起來也像範例。下面是它底下的骨架——能夠真的失敗的最小測試平台：

```verilog
`timescale 1ns/1ps

module tb_my_design;

    reg clk = 0;
    reg rst = 1;
    wire result;

    my_design uut (.clk(clk), .rst(rst), .result(result));

    always #5 clk = ~clk;          // 100 MHz 時脈

    initial begin
        $dumpfile("build/wave.vcd");
        $dumpvars(0, tb_my_design);

        repeat (2) @(posedge clk);
        rst = 0;

        @(posedge clk);
        #1;                        // 等 non-blocking assignment 生效
        if (result !== 1'b1)
            $fatal(1, "result should be high after reset, got %b", result);

        $display("tb_my_design: PASS");
        $finish;
    end

endmodule
```

真正在做事的是三個地方：

* **`$fatal` 才是讓壞掉的設計變成紅色 CI 的東西。** `$display` 印完就繼續跑，而模擬器兩種情況都回傳 0——一個回報了失敗卻沒有失敗的測試只是裝飾。`$fatal` 會回傳非零，那才是 `make sim` 和工作流在讀的東西。
* **邊緣之後的 `#1`。** `@(posedge clk)` 是*在*邊緣當下恢復，此時 non-blocking assignment 還沒生效，所以在那裡讀到的是上一拍的值。相對檢查照樣會過，這正是它難以察覺的原因。
* **`$dumpfile`/`$dumpvars` 來自你**，不是來自工具。沒有它們，上面那個斷言炸掉的時候你沒有波形可以看。

試試看：把 `src/blinky.v` 改壞，執行 `make sim`，看著它變紅。一個你從沒看它失敗過的測試平台，是一個你不知道它有沒有用的測試平台。

## 測試失敗的時候：去看波形

`make sim` 會寫出 `build/wave.vcd`——每一條訊號、每一個週期，前提是你的測試平台有上面骨架裡那兩行 `$dumpfile`/`$dumpvars`。用 GTKWave 打開，或用 Dev Container 已經裝好的 **WaveTrace** 擴充套件（直接點那個 `.vcd` 檔）。失敗的斷言告訴你設計*錯了*，波形才告訴你*為什麼*。

`*.vcd` 在 `.gitignore` 裡，而 CI 會把每次執行的副本留在 `chipforall-build-artifacts` 上傳中保存五天——所以只在 CI 上失敗的測試，一樣可以回頭檢查。

## 用 Python 寫測試平台

`make cocotb` 執行 [cocotb](https://www.cocotb.org/) 測試：用 Python coroutine 驅動同一份 RTL，底層是同一個模擬器。它是 `test/tb_blinky.v` 的另一種選擇，不是取代——哪種語言適合這個測試就用哪種。

```bash
make cocotb
```

`test/test_blinky_cocotb.py` 這個範例展示的是 Python 在這裡明顯佔優的一件事：直接寫入設計**內部**的訊號。

```python
dut.count.value = (1 << (WIDTH - 1)) - 1   # 停在翻轉前一拍
await tick(dut)
assert dut.led.value == 1
```

用這個方式驗證「led 就是計數器最高位元」只需要四個 cycle。Verilog testbench 要做到同一件事，只能覆寫 `WIDTH`（閘級 testbench 做不到），或是老實跑完 2^25 個 cycle。

Verilog 那個邊緣的坑在這裡一樣成立：`RisingEdge` 是在時脈邊緣**當下**恢復執行，此時 non-blocking assignment 還沒生效，所以檔案裡每次讀值前都再等一個 `Timer`。

## 隨機刺激與參考模型

`test/test_blinky_random.py` 是驗證的另一半。directed test 針對某人挑的幾個時刻做斷言；這一支則建立一個「設計應該怎麼動」的模型，在沒有人手寫的刺激下，每個 cycle 都拿來對一次。

三個部分，每個大約十行：

* **模型**——`BlinkyModel`，用 Python 把 blinky 的行為再寫一次。刻意不是 RTL 的逐行翻譯：一個會重複設計錯誤的模型，不可能跟設計意見不合。
* **刺激**——隨機的起始計數與隨機的 reset 脈衝，五個視窗裡有兩個固定放在 `led` 會變的位置，這樣一次執行不會整場盯著一條不動的訊號。
* **scoreboard**——每個時脈之後把 `led` 和模型比對，失敗時印出第幾個 cycle、兩邊的值，以及那個視窗的起始計數。

```bash
make cocotb                   # 每次換一個 seed
make cocotb SEED=1789965785   # 完全重現某一次
```

cocotb 自己會 seed Python 的 `random` 並把用的 seed 印出來，所以 CI 上的失敗可以照著那一行在你機器上重現。

`led` 從頭到尾沒動過的話，這個測試也會失敗——200 個綠色 cycle 盯著一條常數訊號，什麼都沒證明，而一個會為此回報 PASS 的測試套件，正是這個專案花最多力氣在避免的東西。

它不檢查 reset 的*時序*：刺激只在時脈邊緣之後才動 `rst`，所以非同步 reset 和同步 reset 在這裡看起來一樣。那是靜態時序的問題，`make gds` 已經在報告了。

## 模擬閘級電路，而不只是 RTL

`make sim` 驗證的是你寫的 Verilog，它並不能證明工具從中產生的 netlist 也對。latch 被誤推斷、reset 處理方式、合成器如何解讀有歧義的 `always` 區塊——這些都夾在兩者之間，而且從 RTL 看不出來。`make gatesim` 補上這一段：它拿 `make gds` 留下的閘級 netlist（`runs/<tag>/final/nl/`），對著 Sky130 元件自己的 Verilog model 跑模擬。

```bash
make gds       # 產生 netlist
make gatesim   # 模擬它
```

它需要自己的 testbench，放在 `test/gate/`，因為合成會把參數固定下來：`test/tb_blinky.v` 靠把 `WIDTH` 設成 4 來縮小設計，而 netlist 裡已經沒有 `WIDTH` 可以設。因此 `test/gate/tb_blinky_gl.v` 只驅動真正的接腳，並觀察 `led` 走完一個完整的除頻週期——整整 2^26 個 cycle，大約需要四分鐘（CI runner 上實測 3 分 36 秒）。

這個代價就是為什麼 CI 只在推送到 `main` 與 `v*` tag 時跑 `make gatesim`，而不是每個 pull request 都跑。

## 不重跑整條流程的迭代方式

第一次 `make gds` 大約三分鐘。之後你會改的東西——`FP_CORE_UTIL`、`CLOCK_PERIOD`、floorplan——多半不需要重做合成，所以把恢復上次執行的旗標傳給 LibreLane：

```bash
make gds LIBRELANE_ARGS="--last-run --from floorplan"
```

它讀的是 `runs/` 裡上一次的執行結果，這也是為什麼 `make clean` 不會動那個目錄，要清掉它得用 `make distclean`。

## 看看電路長什麼樣

```bash
make schematic
```

畫出 `build/schematic.svg`——你的設計以 flop、加法器、多工器呈現，帶著你取的名字。用瀏覽器開，或在 VS Code 裡點一下都行；它是 SVG，不需要任何特別的東西才能看。

這不是 netlist 的圖。`make synth` 會跑完整合成，留下幾百個技術元件，沒有人能從那張圖看懂自己的設計。`make schematic` 停得更早，停在電路還看得出原始碼樣子的地方。

不到一秒，所以每改一次都可以跑——和 `make gds` 不一樣。

## 在容器內開發

本專案附有 [Dev Container](https://containers.dev/)。用 GitHub Codespaces 開啟，或在 VS Code 選擇「在容器中重新開啟」，即可取得與 CI 相同的映像檔，Verilog 相關擴充套件也已裝好。`Makefile` 會偵測到自己已在容器內，直接呼叫工具，而不會再疊一層容器。

`make gds` 在這裡面也能跑：容器內建了一個自己的 Docker daemon 給 LibreLane sidecar 用。如果 `make gds` 說它找不到 Docker daemon，重建一次 Dev Container 就是它要的。

兩件要知道的事：

* **容器內以 `root` 執行。** 在 Linux 主機上，這代表它寫進 `build/` 的檔案擁有者會是 `root`，從主機執行 `make clean` 可能需要 `sudo`。改用一般使用者會讓 Codespaces 無法連線。
* **在 Codespace 裡要注意磁碟。** 內部 daemon 有自己的映像檔儲存區，所以 LibreLane 映像檔是重拉一份而不是跟主機共用，再加上 Sky130 PDK 的 3GB。在最小規格的 Codespace 上那已經吃掉大半個磁碟——選大一點的規格，或者改從自己的主機跑 `make gds`。

習慣用自己的編輯器？`make shell` 可以從任何終端機進入同一個映像檔。

## 設定參考

`config.yaml` 是一份 [LibreLane](https://github.com/librelane/librelane) 配置檔。不屬於 LibreLane 的 key 前面加 `//`，它會直接忽略——這就是一份檔案能同時給兩個工具用的原因。

| Key | 作用 |
|---|---|
| `DESIGN_NAME` | 你的頂層模組名稱。其他地方都從這裡讀。 |
| `VERILOG_FILES` | 可合成的原始碼。一行一個檔案：LibreLane 會把每一項當成字面路徑驗證，不展開 `**`。 |
| `"//TEST_FILES"` | 給 `make sim` 的 Verilog 測試平台。可以用萬用字元。 |
| `"//SIM_TOP"` | 要 elaborate 的測試平台模組。`"//TEST_FILES"` 對到超過一個檔案時必填。 |
| `"//COCOTB_TESTS"` | 給 `make cocotb` 的 Python 測試平台。選用。 |
| `"//GATE_TESTS"` / `"//GATE_TOP"` | 給 `make gatesim` 的閘級測試平台。選用。 |
| `CLOCK_PORT` / `CLOCK_PERIOD` | 要約束的時脈，以及它的週期（ns）。 |
| `FP_SIZING` / `FP_CORE_UTIL` | die 怎麼算出來的——見下。 |
| `PDK` / `STD_CELL_LIBRARY` | Sky130 與它的標準元件庫。保持原樣。 |

**晶片尺寸會自己長。** `FP_SIZING: relative` 依 `FP_CORE_UTIL`（core 要放多滿，這裡是 40%）算出 die，所以較大的設計會得到較大的 die，而不是「放不下」。繞線太擠就調低，想要更小的晶片就調高。

仍然可以固定尺寸：把 `FP_SIZING` 改成 `absolute`，並加上 `DIE_AREA: [0, 0, 寬, 高]`。但用 relative 的時候不要把 `DIE_AREA` 留在檔案裡——流程已經不讀它了，GDS stream-out 卻還是會照它畫晶片邊界，signoff 就會對著一個沒人用的邊界失敗。

檔案中其餘的 key 都屬於 LibreLane，完整清單見[它的文件](https://librelane.readthedocs.io/)；這個引擎讀哪些，見 [c4o-core README](https://github.com/anlit75/c4o-core)。
