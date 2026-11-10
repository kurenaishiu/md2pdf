# MD2PDF

在 macOS 上把 Markdown 轉成 PDF 的小工具。按一個快捷鍵就能從編輯器（VS Code / Antigravity IDE）轉檔，轉完自動跳回原本的編輯器。

## 運作流程

```
.md 檔
  │ ① Pandoc（含 KaTeX 公式、row-header-table.lua 過濾器、github-markdown-light.css 樣式）
  ▼
HTML（只放在記憶體裡，用本機 127.0.0.1 暫時伺服器提供）
  │ ② 在 Safari 開啟，由「你」按 Cmd+P → 存成 PDF
  ▼
PDF（程式偵測到檔案寫完且內容穩定）
  │ ③ 關閉 Safari 分頁，並用 `open -a <編輯器>` 跳回原本的 .md
  │ ④ mask_pdf_corners.py 用 PyMuPDF 清除指定頁角的文字
  ▼
完成的 PDF（與 .md 同資料夾、同檔名）
```

> [!NOTE]
> 第 ② 步需要手動列印。程式會等最多 **2 分鐘**，超過就逾時結束。

## 專案結構

| 檔案 | 用途 |
|---|---|
| `md2safari.swift` | 主程式原始碼（唯一的 Swift 檔） |
| `build.sh` | 編譯腳本，輸出 `bin/md2pdf` |
| `bin/md2pdf` | 編譯後的執行檔（不進 git） |
| `github-markdown-light.css` | GitHub 風格、針對列印調整的樣式 |
| `row-header-table.lua` | Pandoc Lua 過濾器：表格標題列/欄與換頁標記 |
| `mask_pdf_corners.py` | 轉完後清除頁角文字的 Python 腳本 |

主程式用 `#filePath` 找旁邊的 CSS、Lua 與 Python 檔，所以**這些檔案必須和 `md2safari.swift` 放在同一個資料夾**。

## 事前需求

1. **macOS**，並安裝 Xcode Command Line Tools（提供 `swiftc`）
2. **Pandoc**：`brew install pandoc`
3. **Safari**
4. **Python 環境**：需要 PyMuPDF（`fitz`）。程式目前寫死使用：
   `/opt/homebrew/Caskroom/miniforge/base/envs/MD2PDF/bin/python`
   （conda 環境名稱 `MD2PDF`；若位置不同，修改 `md2safari.swift` 裡的 `pythonPath`）
5. **網路**：只有第一次遇到 Mermaid 圖表時需要，之後會快取在 `~/Library/Caches/md2pdf/`

## 編譯

```bash
./build.sh
```

等同於：

```bash
swiftc -O /Users/kurenai/Documents/MD2PDF/md2safari.swift -o /Users/kurenai/Documents/MD2PDF/bin/md2pdf
```

> [!IMPORTANT]
> 一定要用**絕對路徑**編譯。用相對路徑的話 `#filePath` 也是相對的，執行時會找不到 CSS / Lua / Python 檔。改了 `md2safari.swift` 之後要重新執行 `./build.sh`。

## 使用方式

### 命令列

```bash
cd 檔案所在資料夾
/Users/kurenai/Documents/MD2PDF/bin/md2pdf document.md
```

PDF 會輸出到**目前工作目錄**，檔名與 `.md` 相同。程式只接受一個參數（輸入檔），沒有其他選項。

### 在編輯器裡一鍵轉檔

快捷鍵 `Cmd+Opt+P`，只在編輯 Markdown 時有效。設定檔在各編輯器的使用者資料夾：

| 編輯器 | 設定資料夾 |
|---|---|
| VS Code | `~/Library/Application Support/Code/User/` |
| Antigravity IDE | `~/Library/Application Support/Antigravity IDE/User/` |

**`keybindings.json`**

```json
[
    {
        "key": "cmd+alt+p",
        "command": "workbench.action.tasks.runTask",
        "args": "MD2PDF",
        "when": "editorLangId == 'markdown'"
    }
]
```

**`tasks.json`**

```json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "MD2PDF",
            "type": "shell",
            "command": "/Users/kurenai/Documents/MD2PDF/bin/md2pdf",
            "args": ["${file}"],
            "options": {
                "cwd": "${fileDirname}",
                "env": {
                    "MD2PDF_RETURN_APP": "Antigravity IDE"
                }
            },
            "group": { "kind": "build", "isDefault": true },
            "presentation": {
                "echo": false,
                "reveal": "silent",
                "focus": false,
                "panel": "shared",
                "showReuseMessage": false,
                "clear": true
            },
            "problemMatcher": []
        }
    ]
}
```

VS Code 的 `tasks.json` 相同，只是 `MD2PDF_RETURN_APP` 改成 `"Visual Studio Code"`。改完設定後，執行 `Developer: Reload Window` 讓編輯器重新讀取。

### 環境變數 `MD2PDF_RETURN_APP`

轉完後要跳回的 app 名稱（`open -a` 使用的名稱）。

| 值 | 結果 |
|---|---|
| `Visual Studio Code` | 跳回 VS Code |
| `Antigravity IDE` | 跳回 Antigravity IDE |
| 未設定或空白 | 預設跳回 `Visual Studio Code` |

## 支援的 Markdown 功能

- **數學公式**：`$x^2$`、`$$...$$`（KaTeX）。超過 12 位的長數字會自動允許換行
- **Mermaid 圖表**：使用 ` ```mermaid ` 程式碼區塊
- **表格標記**（寫在表格正上方，單獨一行）：
  - `@column-header`：第一欄當作標題欄
  - `@no-header`：無標題列的表格
  - 或用 `::: {.column-header}` / `::: {.row-header}` / `::: {.no-header}` 包住表格
- **換頁**：`::: {.nextpage}` 區塊會加上 `nextpage-break` class，由 CSS 控制換頁
- 其他 Pandoc Markdown 語法皆可使用

## 常見狀況與疑難排解

| 狀況 | 原因 / 處理 |
|---|---|
| `Timed out waiting for the PDF after 2 minutes` | 2 分鐘內沒有在 Safari 存檔。重新執行並盡快 `Cmd+P` 存到畫面提示的路徑 |
| 存檔路徑不對 | 要存成提示的 `Print from Safari and save the PDF to:` 那個路徑（與 `.md` 同資料夾） |
| `The saved file is not a valid PDF` | 存的檔案不是 PDF 格式，請在列印對話框選「存儲為 PDF」 |
| `Could not find .../mask_pdf_corners.py`（或 CSS、Lua） | 編譯時用了相對路徑，或這些檔案被搬離 `md2safari.swift` 所在資料夾。用 `./build.sh` 重新編譯 |
| `Failed to launch Pandoc` / `Pandoc failed` | 未安裝 Pandoc，或 `pandoc` 不在 PATH。執行 `brew install pandoc`；從編輯器啟動時 PATH 可能不含 `/opt/homebrew/bin` |
| `PDF masking failed` / 找不到 python | conda 環境 `MD2PDF` 不存在或沒裝 PyMuPDF：`pip install pymupdf`，或修改 `pythonPath` |
| 轉完跳到錯的編輯器 | `tasks.json` 的 `MD2PDF_RETURN_APP` 設錯或沒設（預設是 VS Code） |
| 按 `Cmd+Opt+P` 沒反應 | 先 Reload Window；再到鍵盤快捷鍵設定（`Cmd+K Cmd+S`）搜尋 `cmd+alt+p` 看是否衝突；確認目前檔案是 Markdown |
| Safari 第一次要求授權 | 程式用 AppleScript 關閉 Safari 分頁，需要在「系統設定 → 隱私權與安全性 → 自動化」允許終端機/編輯器控制 Safari |
| `Could not load Mermaid renderer` | 第一次使用需要網路下載 Mermaid；之後會用 `~/Library/Caches/md2pdf/mermaid-v11.17.min.js` 快取 |
| 已存在同名 PDF | 會被覆蓋。程式用「檔案大小與修改時間有變化且穩定」判斷是否存好 |

## 已知限制

- 絕對路徑寫死：Python 路徑（`pythonPath`）與編輯器 task 裡的 `bin/md2pdf` 路徑。換電腦或搬資料夾要一起改
- 僅限 macOS，且需手動在 Safari 列印
- 頁角遮罩尺寸固定為 10 cm × 2 cm，作用在每頁的左上、右上、左下三個角落，修改請編輯 `mask_pdf_corners.py`
- 頁面小於 10 cm × 2 cm 時遮罩腳本會報錯

## License

MIT License.
