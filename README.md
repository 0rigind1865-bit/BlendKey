# BlendKey 融鍵

專為 macOS 設計的繁體中文注音輸入法，主打**中英混輸零阻礙**：
打字時不必切換輸入來源，中文、英文、標點一氣呵成。

```
我在google上查資料？   ← 全程沒有按過「切換輸入法」
```

## 特色

- **智慧整句組句**——連續打注音自動組詞成句（詞圖＋動態規劃），游標移回可改字，改過的字會被記住（使用者詞庫學習）
- **自動造詞**——同一串音節連續兩次被你改字後上屏（例如兩次都改出「融鍵」），自動學成使用者新詞，之後整個詞一次組出來；學習資料在 `~/Library/Application Support/BlendKey/userphrases.json`，刪掉即重置
- **Shift 單擊切換中／英**——Windows 新注音使用者零學習成本；切換時游標旁閃現「中／A」提示
- **Shift＋字母直出英文**——打縮寫（USB、OK）不用切模式
- **英文自動偵測**——直接打 `google`，輸入法發現「這串不像注音」（命中英文詞典，或注音鍵位被反覆覆寫），跳出 `⇥ google` 提示，按 Tab 上字
- **反向偵測**——英文模式下忘了切回來就直接打注音？連續兩個乾淨音節（零覆寫、含數字聲調、詞庫查得到）就自動切回中文模式並閃現「中」提示；已打出的英文字母不動，從下一鍵開始組字
- **長按直出**——按住 `5` 出數字 5、按住 `g` 出字母 g（鍵盤自動重複當訊號；聲調鍵 3/4/6/7 在空組字區本來就直接放行成數字）
- **全形標點**——`<` `>` `?` `!` `'` `[` `]` 等直接出 ，。？！、「」
- **Mac 原生質感**——直式候選清單（比照系統內建注音）、毛玻璃（NSVisualEffectView）、圓角連續曲線、跟隨游標定位

## 安裝

```bash
scripts/build-data.sh   # 首次：下載並轉換詞庫（小麥注音，MIT）
scripts/install.sh      # 建置、打包、安裝到 ~/Library/Input Methods
```

> **首次安裝必須登出再登入**（Apple 已證實的系統限制，FB23026482），
> 然後到「系統設定 › 鍵盤 › 輸入法 › ＋ › 繁體中文」加入「融鍵」。
> 之後更新只要重跑 `scripts/install.sh`，切個輸入框就生效。

## 按鍵一覽（中文模式）

| 按鍵 | 行為 |
|------|------|
| 注音鍵（大千） | 組字，調號落下即成音節 |
| 空白 | 組字中＝一聲；有組字區＝開候選窗 |
| ↓ | 開游標右側詞的候選窗；窗內＝下一個候選 |
| ↑ | 窗內＝上一個候選 |
| ←→ | 移動游標（改字用）；窗內＝翻頁 |
| 1–9 | 選候選 |
| Caps Lock | 亮＝英數直通模式（所有按鍵原樣輸出） |
| Tab | 接受英文偵測提示 |
| 長按字母／數字鍵 | 直接輸出該字元（英文字母、數字），不當注音 |
| Enter | 上屏 |
| Esc | 清組字／關候選窗 |
| Shift 單擊 | 切換中／英 |
| Shift＋字母 | 英文字母直出 |

## 開發

```bash
swift test               # 37 個核心單元測試（組字、斷詞、混輸、學習）
swift run blendkey-cli   # REPL：不安裝也能玩整條組字管線
log stream --level debug --predicate 'subsystem == "org.blendkey.inputmethod.BlendKey"'
```

架構：`BlendKeyCore`（純邏輯，零 AppKit 依賴，全部可測）＋ `BlendKey`（InputMethodKit 殼層）。
純 SwiftPM，不需要 Xcode 專案檔；`scripts/package-app.sh` 負責組 .app bundle 與簽章。

## 已知限制

- NSMenu 與開／存檔對話框中收不到 flagsChanged，Shift 切換暫時失靈（平台限制）
- 斷詞用 unigram＋長詞偏好，罕見句型可能要手動改字（升級路徑：bigram）
- 選單列圖示不隨中英模式變化（HUD 已涵蓋；輸入模式架構會逼出第二次登出，不划算）

## 授權

程式碼 MIT。詞庫轉換自 [McBopomofo 小麥注音](https://github.com/openvanilla/McBopomofo)（MIT，見
`Resources/data/LICENSE-McBopomofo.txt`）；英文詞表使用 macOS 內建 `/usr/share/dict/words`（公有領域）。
