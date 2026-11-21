# 第三方來源與授權

本專案自有程式與文件採用 [Apache License 2.0](../license)。本文件列出的第三方內容各自維持原有授權、著作權及必要聲明，不因本專案採用 Apache-2.0 而改變；下列 MIT、BSD 或供應商條款不能互相套用，也不代表已取得第三方二進位重新散布許可。

## Win11Debloat

- 上游：[Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat)。
- 本包釘選提交：`5d88bfe9ef2be5a8a643166a6400eb78a30c46ec`，依據 [debloat_profile.json](../modules/debloat/debloat_profile.json)。
- 原始碼與必要資產保存在 `modules/debloat/win11debloat`，包括上游的 `Assets/Images/menu.png` 與空白開始選單資產 `Assets/Start/start2.bin`。
- 保留上游 [MIT LICENSE](../modules/debloat/win11debloat/LICENSE)、作者聲明及 README。`start2.bin` 的用途見同目錄的 `What is this file.txt`；它是上游提供的空白範本，不是從使用者電腦匯出的個人開始選單。
- 本工具透過 CLI 呼叫上游，採用的清理項目另由 `debloat_apps.txt`、`debloat_profile.json` 控制。
- 精簡版本保留 354 個上游檔案；本專案固定 CLI 使用 `zh-TW` 並保留 `en-US` 作 fallback，排除其他 11 個語系的 44 檔。固定 wrapper 直接啟動主腳本，不使用上游 `Run.bat` 或 `Scripts/Get.ps1` 啟動器，因此排除這兩檔；GUI 定義、登錄檔、執行腳本、資產和上游 `.gitignore` 暫保留。另排除上游 `.github/`、`Tests/` 及 `Scripts/Build-Release.ps1`、`Scripts/Run-Tests.ps1`，共 83 個開發用檔案。上游 `.gitignore` 仍保護備份及使用者設定；不要用同步作業覆蓋既有個人資料。

維護者可用本機已取得上述固定提交物件的 Git 倉庫重現。工具不下載上游、不執行 Win11Debloat，以下目標必須是尚不存在的路徑；`stage` 目的地須在上游 Git 工作樹及控制目錄之外。呼叫者須使用自行控制且無並行寫入的暫存父目錄；獨占建立檔案不代表已檢查 ACL 或可抵抗並行寫入：

```powershell
go run ./script/package/win11debloat_sync lock --source <本機上游Git倉庫> --output <新鎖檔路徑>
go run ./script/package/win11debloat_sync stage --source <本機上游Git倉庫> --lock script/package/win11debloat_sync/upstream.lock.json --output <新暫存目錄>
go run ./script/package/win11debloat_sync verify --lock script/package/win11debloat_sync/upstream.lock.json --vendor modules/debloat/win11debloat
```

鎖檔由固定提交及 tree 產生，記錄上游檔案路徑、Git blob 身分、模式、SHA-256 與是否保留。`stage` 重新核對本機 Git 物件與鎖檔後產生新樹；`verify` 離線核對交付檔案集合及 SHA-256，拒絕缺漏、額外檔案與不符內容。離線驗證以程式中固定的鎖檔 SHA-256 及儲存庫內受審查的鎖檔為基準；兩者同屬受審查來源，不能防止能修改整個儲存庫者，也不能自行證明本機 Git 物件的遠端來源。上游版本更新時，必須重新核對來源、排除規則、執行依賴與鎖檔，不自動接受未分類內容。

## Microsoft Sysinternals Autologon

- 官方來源：[Autologon](https://learn.microsoft.com/en-us/sysinternals/downloads/autologon)。
- 本機完整包使用 `modules/accounts/Autologon64.exe`，檔案版本為 3.10；執行模組會驗證 Microsoft 數位簽章。
- 此 EXE 不納入 Git。從官方取得工具並遵守其授權；不要因本專案包含呼叫腳本就推定可重新散布該二進位。

## 裝置驅動

十二個驅動封存檔保留於主程式之外的可選獨立包 `windows_driver_packages/nuc8`，不納入 Git。檔名及已核對的 SHA256 範本見 [manifest.json](../drivers/nuc8i7hvk_hnk/manifest.json)；獨立包自身使用 `manifest.json` 核對完整性。

Wi-Fi 的原始 BurnManifest UX 內 27 份語系 EULA 與藍牙原 MSI/CAB 的兩份授權文件已逐位元組保留至獨立包，來源及雜湊記錄於 manifest 的 Provenance.PreservedLicenseFiles。Realtek、SD、CIR 的原擷取樹已逐檔查閱授權類檔名；SD MSI 的 File／Control 表亦唯讀查閱，未發現另一份可保留的外掛授權文字。LAN 既有 license.txt 與 3rd_party_licenses.txt、MEI 及 Intel Graphics 的原授權檔保持。這是已取得原文的保留查核，不宣稱安裝器所有資源或每份原廠條款均已解讀，也不新增或推定二進位重新散布許可。

目前涵蓋晶片組、Serial IO、UCM、AMD／Intel 顯示、Wi-Fi、藍牙、乙太網路、音效、MEI、SD 及 CIR；精確版本與來源見 [機型說明](../drivers/nuc8i7hvk_hnk/readme.md)。這些檔案具有各供應商自己的授權，不能把本專案或 Win11Debloat 的授權視為驅動的散布許可。儲存庫只追蹤雜湊清單，不承諾第三方下載位置永久有效。

## Windows 內建元件

OpenSSH Server、Windows Update、Sysprep 與 Windows PowerShell 使用目標系統提供的元件；沒有把它們的二進位加入 Git。離線環境若尚未快取 OpenSSH 安裝來源，仍須接網或另外準備符合目標 Windows 的元件來源。

## Go 維護工具與 HTML5 解析器

- 工具鏈使用 [Go 官方下載](https://go.dev/dl/)的 Go 1.27.3，Windows 容器 ZIP 的 SHA256 釘選於 `script/docker/install_go.ps1`；SDK 不提交 Git，也不要求一般設定使用者安裝。
- HTML5 解析使用 Go 官方專案 [golang.org/x/net/html](https://pkg.go.dev/golang.org/x/net/html)，釘選模組 `golang.org/x/net v0.62.0`，由根目錄 `go.mod`／`go.sum` 記錄。這是額外依賴，不宣稱僅使用標準庫。
- `go mod vendor` 保留實際需要的 html 與 atom 原始碼；[BSD 類授權 LICENSE](../vendor/golang.org/x/net/LICENSE)及[PATENTS](../vendor/golang.org/x/net/PATENTS)維持上游原名與內容。自有檔名規則僅在此明確第三方路徑例外，不修改上游來源。
- CI 與容器使用 `-mod=vendor`、`GOPROXY=off`、`GOTOOLCHAIN=local`；固定 SDK 在建置階段準備，執行驗收時不自動下載模組或切換工具鏈。
