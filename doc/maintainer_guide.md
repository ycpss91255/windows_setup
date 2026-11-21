# 維護者指南

## 專案架構與依賴方向

本專案對齊 base 將「交付給使用者的執行程式」與「維護儲存庫的工具」分開；Windows 執行樹保留 `core`／`modules`，不將 Linux／Docker 專用的 `dist` 照字面搬入。

| 位置 | 職責 |
| --- | --- |
| `core`、`modules`、根目錄 Init／Windows 入口 | Windows 交付執行樹：帳號、設定、驗收與獨立功能 |
| `script/test` | 測試調度與報告產生 |
| `script/release` | 版本準備、發布門檻與 Release 說明 |
| `script/package` | 從可信來源建立獨立驅動包 |
| `test/powershell/unit`、`integration` | 單元及隔離整合測試案例 |
| `.github/workflows` | 雲端 CI 與發布編排 |

依賴方向為維護工具／測試 → 交付執行樹。`core`／`modules` 不依賴 `script`、`test` 或 `.github`；一般使用與獨立驅動安裝不需要儲存庫維護工具。

自有原始檔與目錄使用小寫與底線，新驅動安裝日誌位於 `modules\drivers/driver_logs`。為保留已部署電腦的續跑資料，`%ProgramData%\NUC8-Setup`、`NUC-Init`、`CustomHostsSync` 及既有排程工作名稱維持相容；這些是系統既存識別，不是新增的儲存庫目錄。第三方 `win11debloat` 內部目錄及內容保持上游原樣。

## 維護者版本發布

版本發布參考 base 的 PR、CI gate 與標籤流程；Windows 測試及來源檢查保留本專案的實作。不是每次合併都自動增加 patch 版本。維護者先選擇版本、整理使用者可見的變更，再經 PR、CI 與標籤發布。

### 準備版本與 Pull Request

日常變更寫入 `doc/changelog/changelog.md` 的 `## [Unreleased]`。要發布時，先選擇尚未使用的新版本（不是目前 `.version` 或既有標籤），在工作分支執行：

```powershell
$newVersion = Read-Host '輸入尚未使用的新版本（vX.Y.Z 或 vX.Y.Z-rcN）'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\script\release\prepare_release.ps1 -Version $newVersion
```

此命令將 Unreleased 區段提升為指定版本、寫入 `.version`，不提交、不建立標籤也不推送。審查版本內容後，以中文提交並開啟 Pull Request。主分支要求 `ci-rollup` 通過；合併與提交規範見 [維護規範](../agents.md)。版本必須符合 `vX.Y.Z` 或 `vX.Y.Z-rcN`。

### 標籤與發布門檻

合併後，確認 main 的 CI 通過、版本檔與 changelog 一致，再在該提交建立標籤：

```powershell
git switch main
git pull --ff-only
$version = (Get-Content -LiteralPath .\.version -Raw).Trim()
git tag -a $version -m $version
git push origin "refs/tags/$version"
```

同一個 Windows workflow 接受 main 推送、Pull Request、手動執行與版本標籤。`isolated-tests` 完成後由 `ci-rollup` 統一回報；只有版本標籤通過測試，且提交位於 main 歷史、`.version` 與 changelog 精確匹配，才發布 Release。RC 標為預覽版；正式版本整合同版 RC 的版本紀錄。既有標籤與版本不應刪除、移動或重用。

主分支與 `v*` 標籤使用要求 `ci-rollup` 的保護，管理員也遵守；禁止強制推送或刪除。遠端設定的實際啟用狀態以 GitHub Rules／Branch protection 為準，檔案本身不能啟用遠端保護。

### 下載內容與保留期限

從 GitHub Release 使用內建 **Source code (zip)** 或 **Source code (tar.gz)** 下載來源，不額外上傳重複來源 ZIP／SHA256。內建來源封存檔的根目錄名稱由 GitHub 決定。若使用快速開始的 USB 自動尋找指令，請改名為 `windows_setup` 並放在 USB 根目錄；腳本本身可放任意路徑，手動呼叫該位置的 `init.cmd` 即可。

Release 不一定提供驅動資產；所有電腦（包括 NUC）都可在 `windows.cmd` 選包提示按 Enter 略過。若該版提供適合本機型號的獨立驅動包且需要安裝，依 [準備獨立驅動包](../readme.md#準備獨立驅動包) 下載同版 ZIP、解壓後選取該資料夾。資產檔名、大小、SHA256、機型設定檔與包內 manifest 雜湊，列在該版來源的 [驅動資產清單](../script/release/driver_release_assets.json)；只選擇自己機型對應的包，不把其他型號包套用到本機。

- 來源不包含 `.git`、驅動 ZIP、Autologon EXE、實機 Reports 或密碼暫存；來源檢查會拒絕錯誤追蹤的敏感檔案。
- 依 [來源包準備說明](../readme.md#從原始碼準備完整工具包) 補齊所選功能需要的二進位，不能把來源 ZIP 當成完整離線安裝包。
- Actions 的 CI 報告附件保留 7 天；Actions 日誌保留期由儲存庫設定決定。實機續跑紀錄仍留在原機，不提交進 Git。
- Release 提供來源、品質證據與該版明確宣告的可選驅動資產，不會連線部署到任何電腦。
- v0.1.x 已發布的舊來源 ZIP／SHA256 保持原樣，新流程不回寫舊版本。

### 維護者準備獨立驅動資產

一般使用者只需下載與解壓，不需執行本節命令。維護者先完成獨立驅動包的離線完整性驗證，再於來源目錄載入打包函式，將已驗證的完整包封存到來源樹外的新檔案：

```powershell
. .\script\release\driver_release_library.ps1
New-DeterministicDriverArchive -PackageDirectory '已驗證的獨立包資料夾' -OutputPath '來源樹外的資料夾\driver_機型.zip'
```

封存使用固定 UTC 時間、相對路徑與排序，且不重壓包內現成 ZIP。將實際檔名、位元數、SHA256、ProfileId、manifest SHA256 加入上述資產清單的當版紀錄，經 PR、CI 與獨立審查後再合併、建立該版標籤。歷史版本紀錄保留；未宣告驅動資產的其他版本不受影響。

推送標籤後，立即從該標籤的來源目錄建立一次性草稿：

```powershell
.\script\release\stage_driver_release.ps1 -Version vX.Y.Z -Repository ycpss91255/windows_setup -AssetDirectory '已封存的資產資料夾'
```

此命令只建立尚未公開的暫時草稿，先核對標籤位於 main、遠端提交一致以及本地資產雜湊。標籤 CI 全綠後，CD 才會核對草稿身分、既有驅動與全部品質附件，最後一次發布為不可變 Release。已有其他草稿、上傳不完整或雜湊不符會停止，保留現場供維護者檢查，不覆寫或刪除既有版本。若建立草稿太晚造成 CD 失敗，先核對草稿完整，再選擇該次執行的「重新執行所有工作」，重新產生同 attempt 的分片及品質證據；勿只重跑發布工作、移動標籤或跳過品質門檻。

### 本機檢查發布內容

對已提交、版本檔及 changelog 已一致的來源執行：

```powershell
$version = (Get-Content -LiteralPath .\.version -Raw).Trim()
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\script\release\build_source_release.ps1 -Version $version -OutputDirectory "$env:TEMP\windows_setup_release_check"
```

此命令驗證來源並產生 Release 說明，不再重複打包來源 ZIP；不建立標籤、不推送、不發布，也不代表雲端 CI 已通過。

### 檔名與舊版相容性

本專案的自有檔案統一小寫 snake_case，例如 `init.cmd`、`windows.cmd`、`script/test/run_ci.ps1`；Windows 不分大小寫不代表 Linux／GitHub 也能接受舊拼法。`agents.md` 也依此命名，部分工具不再自動發現原本大寫 AGENTS.md 的規範，維護時須主動讀取本檔。

第三方 Win11Debloat 原始碼、授權及供應的 Autologon／驅動封存檔保留原始檔名，不改上游契約或內容。既有每機報告、排程 worker、ProgramData 目錄與系統固定名稱也保留既有契約，避免失去續跑資料；這些不是新的儲存庫原始檔。舊報告內的模組檔名會映射到新的腳本名稱，仍檢查同一電腦與使用者，不代表允許沿用他機結果。請用新版入口，不另保留重複的舊檔名腳本。

### 自動需求驗收與獨立審查

PR 與 main 的 `requirements-gate` 讀取同一次 PS5.1 測試產物，驗證來源、統計、JUnit／JSON 狀態、文件連結、隱私與 base 徽章規格，並用破壞性負例確認錯誤會被拒絕；`ci-rollup` 必須同時取得測試與需求驗收成功才能合併。PR 的證據保留原分支身分，不會冒充 main。

Pages 部署後匿名讀取首頁、main 報表、JSON／Markdown／JUnit、runtime 及分層 SVG、README 的原生 CI／coverage 徽章，以及歷史版本頁。驗收會重算 `repo_coverage.json`、`coverage_inventory.json`、`coverage.xml`，核對本次提交、Actions 來源與實際 checkout 的 runtime 來源清單；量測必須完整，且 `Covered × 100 >= Executable × 80` 才能通過。分項資訊保留在報表與 Actions 摘要，不要求 README 顯示分項徽章。CDN 只有限重試，舊證據或不一致會失敗，無需 agent 代替腳本處理。

審查以本次變更、實際驗證及最新提交為準；發現問題後修正並重新核對受影響需求，不將先前提交的通過結果套用到修改後版本。具體代理分工依當次授權安排；儲存庫契約見 [維護規範](../agents.md)。

測試與提交規範以 [維護規範](../agents.md) 為準。

### 自有測試暫存的預覽與清理

維護者可用 Go 執行 `go run ./script/test/clean_test_artifacts` 管理本工具新建的拋棄式測試資料夾。先在 Go `os.TempDir()` 所取得的目前程序暫存目錄之下，以 `init <新根目錄>` 建立不存在的專用根目錄，再用 `create <根目錄> <名稱>` 建立單項。僅在資料確定可拋棄、無續跑或私人證據需求後，以 `finish <根目錄> <名稱> <RFC3339到期時間>` 標記完成。`clean <根目錄> <名稱>` 預設只列出候選項目，尚未驗證完成清單或控制代碼，不能保證實際刪除可成功；明確加上 `--delete` 時才進行完整核對並刪除選定且已到期的單項。以下範例使用一般使用者身分：

完成時工具保留原始所有權標記，另外獨占建立清單，鎖定各項目並記錄相對路徑、識別、大小及 SHA-256；清理前重新核對完整清單。完成後新增或修改項目會拒絕刪除，具名資料流與重解析點亦不支援。清單標記上限為 64 KiB，超過時完成會失敗；此維護工具僅能在 Windows 編譯及執行。

刪除不是交易：失敗前已刪除的子項不會還原。首次刪除前工具在專用根目錄寫入並呼叫檔案同步的復原收據，成功刪完整單項後才移除；失敗時保留收據供識別，並嘗試恢復單項標記。收據本身不授權刪除資料，也不會自動續清。請停止其他寫入，依收據和錯誤訊息人工檢查剩餘資料；處理完畢前保留收據，不要認領未知資料。儲存裝置錯誤可能使收據寫入或同步失敗，此時不會開始刪除。

```powershell
$artifactTemp = [System.IO.Path]::GetTempPath()
$artifactRoot = Join-Path $artifactTemp "disposable_test_root"
go run ./script/test/clean_test_artifacts init $artifactRoot
go run ./script/test/clean_test_artifacts create $artifactRoot sample
go run ./script/test/clean_test_artifacts finish $artifactRoot sample 2026-01-01T00:00:00Z
go run ./script/test/clean_test_artifacts clean $artifactRoot sample
go run ./script/test/clean_test_artifacts clean $artifactRoot sample --delete
```

Windows 暫存路徑可能優先採用 `TMP` 而非 `TEMP`；SYSTEM 程序的暫存路徑可能不同。工具支援暫存根的 8.3 短名稱，會檢查各祖先並以控制代碼核對目錄身分；重解析點仍會拒絕。請使用執行清理的同一身分及環境。檔案同步不保證突然斷電後目錄項目一定持久存在；收據不提供自動回復或續清。此工具不掃描系統 TEMP，也不認領或清理舊的 `windows-setup-*` 目錄。請勿把正式程式碼、未提交工作、私人資料或需保留的證據放入拋棄式目錄。工具會比對列舉及開啟時的檔案識別，並以控制代碼鎖定已開啟項目；檔案識別可能重用，操作期間仍應停止其他程序修改目錄。工具拒絕含連結或重解析點的路徑及項目。Go 是維護工具需求，不是一般 Windows 執行環境的需求。

### 提交訊息輔助檢查

維護者可選擇安裝 `commit-msg` hook；需要 Git、Go 1.27.3 及提交時可用的 Go 執行環境。在本儲存庫根目錄執行 `powershell -File script/test/commitlint/install.ps1`；指定其他目標可加 `-Repository <路徑>`。安裝尊重 Git 的 hooks 路徑，若已有 `commit-msg` 便停止，不覆蓋原檔。移除時請先確認內容，再自行刪除安裝的 hook。hook 參照此工作樹中的工具來源，移動或刪除工作樹後須重新安裝。

也可單獨執行 `go run ./script/test/commitlint lint <訊息檔>`；退出碼 0 代表通過，非 0 代表未通過或執行失敗。檢查標題含漢字，以及訊息中的常見家目錄路徑和憑證指定模式；錯誤不回印原文。這只是有限的提示，可能誤判或漏判，不能證明沒有機密，也不能判定是否為單一任務、TDD 證據是否真實；仍須人工審查。僅檢查啟用後的新提交，不回溯舊歷史。

## 建立獨立驅動包

以下重新建包指令僅供維護者使用，使用者下載與解壓即可。準備符合 [drivers/nuc8i7hvk_hnk/manifest.json](../drivers/nuc8i7hvk_hnk/manifest.json) 的十二個封存檔，並將此範本複製為來源目錄的 `manifest.json`，再執行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\script\package\export_driver_package.ps1 -SourceDirectory "已核對的驅動來源目錄" -OutputDirectory "新的獨立包目錄"
```

設定檔依主機板 Product 精準選擇，沒有對應型號或未選獨立包時略過；已知其他板號不能手動偽裝成 NUC。機型與套件／INF 版本、依賴及官方來源見 [驅動設定檔](../drivers/readme.md)。新增電腦設定檔使用相同安裝引擎，另建立板號白名單與已查核 manifest，不複製安裝程式。

輸出目錄必須不存在。導出會驗證全部封存檔雜湊、產生可攜入口及設定檔雜湊綁定的機型識別；不安裝驅動。取得新驅動應使用原廠可信來源，改版需要重新驗證，不能直接修改 SHA256 來略過檢查。
