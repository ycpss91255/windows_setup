# windows_setup

[![Windows CI](https://github.com/ycpss91255-lab/windows_setup/actions/workflows/windows_tests.yml/badge.svg)](https://github.com/ycpss91255-lab/windows_setup/actions/workflows/windows_tests.yml)

![Runtime: PowerShell | C#](https://img.shields.io/badge/Runtime-PowerShell%20%7C%20C%23-blue?style=flat-square)
[![Coverage](https://ycpss91255-lab.github.io/windows_setup/main/coverage.svg)](https://ycpss91255-lab.github.io/windows_setup/)
[![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](license)

新範圍成功部署後，上方覆蓋率徽章顯示最近一次成功部署 main 的 PowerShell/C# runtime 可執行行覆蓋率；舊徽章在更新前仍代表當時的口徑。點擊徽章可查閱該次報表與來源。若部署失敗，徽章保留上次成功結果，請以 Windows CI 與 Actions 的最新執行結果為準。PR 不更新公開報表。

使用 **v0.2.5 或更新版本**時，在對應的 [GitHub Release](https://github.com/ycpss91255-lab/windows_setup/releases) Assets 下載 `windows_setup_report_<version>.zip`，解壓後開啟 `index.html`，即可查看原生與容器報表及各自的量測範圍（Scope）。v0.2.4 仍使用該版既有的原始品質附件與歷史報表頁，不提供此 ZIP。

Windows 設定工具：以 Init 與 Windows 兩個入口完成帳號初始化、模組設定與後續驗收。本文以繁體中文提供完整操作說明；版本摘要見 [變更紀錄](doc/changelog/changelog.md)，實作與驗證細節以中文 Git 提交及 GitHub Release 為準。

## 快速開始

第一次使用，先在一臺可上網的 Windows 電腦完成 [Release 下載、解壓與官方 Autologon 準備](#從原始碼準備完整工具包)，再把完整資料夾放到 USB。GitHub 的 Source code ZIP 不包含 Autologon EXE，也不是完整離線包；不需要 Git、Go、Docker 或 agent。準備完成後，以下選符合目前畫面的一種，不必先查磁碟代號。

### A．還在地區／Wi-Fi 初始設定畫面

Init 執行必需的三個資產位於 `modules/init/assets`：`hide_oobe.ppkg`、`hide_oobe.xml` 與 `provenance.json`。這三檔缺少或驗證失敗時，Init 會在詢問帳密、建立帳號前停止；不能只複製腳本或自行用空檔代替。發行包另附經逐檔審查的 `payload_baseline.json`，供 CI 獨立核對內容；它不是一般電腦初始化或續跑的必要檔案。

1. 將完整工具包命名為 `windows_setup`，放在 USB 根目錄。插入 USB，按 `Shift+F10`（部分鍵盤需加 Fn）。在 CMD 輸入以下一行找入口，不需要 diskpart：

```cmd
for %d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist "%d:\windows_setup\init.cmd" echo %d:\windows_setup\init.cmd
```

2. 使用找到的完整路徑，例如顯示 `E:\windows_setup\init.cmd` 時輸入 `call "E:\windows_setup\init.cmd"`。E: 只是例子；若列出多份，請選你剛準備的完整工具包。
3. 依中文提示輸入新本機帳號、密碼與確認密碼。設定包套用前會明確詢問是否繼續，因 Windows 可能立即重新啟動；輸入 `YES` 才繼續。取消會保留帳號與無密碼續跑紀錄；仍在 OOBE 時按 Shift+F10，從完整工具包重新執行 `init.cmd`，再確認是否套用。
4. 設定包成功套用並完成 Init 後，登入剛建立的正式帳號，接上網路，直接從完整工具包執行 `windows.cmd`，依下面的 Windows 設定流程繼續；不需要第二次執行 Init。Windows 入口先確認帳號與 OOBE 紀錄，第 4 階段才安裝 SSH。
#### 可選路線：已用 Ctrl+Shift+F3 進入 Administrator 桌面

`Shift+F10` 直接執行 Init 的路線仍可使用。如果你已按 `Ctrl+Shift+F3`，Windows 會重新啟動進入稽核模式的 Administrator 桌面，接著依序操作：

1. 取消自動出現的「系統準備工具／Sysprep」視窗，不在該視窗選擇關機或重新啟動。
2. 從 USB 的完整 `windows_setup` 資料夾執行 `init.cmd`。Init 自動檢查目前帳號與 OOBE 準備條件，不需輸入 `AUDIT`。確認畫面說明的帳號／OOBE 變更後，輸入 `Y`、`YES`（不分大小寫）或按 Enter 同意，再輸入新正式本機帳號、密碼及確認密碼；狀態未知、矛盾或仍有安裝程序時會停止，不要反覆重試。
3. **只有看到「帳號設定已準備完成」才手動重新啟動。** 可使用開始選單的「重新啟動」，或在 CMD 輸入 `shutdown /r /t 0`。如果顯示錯誤或沒有成功文字，先處理錯誤，不把視窗結束當成成功，也不要直接執行 `windows.cmd`。
4. 重開後完成剩餘 Windows 初始設定，登入剛準備的新正式本機帳號。稽核模式的 Administrator 只是準備帳號的暫時身分，不是後續套用設定的目標帳號。
5. 在新正式帳號桌面接上網路，直接執行同一份 USB 工具包的 `windows.cmd`，依下方「接著套用設定」繼續。SSH 由 Windows 第 4 階段安裝，不需要第二次執行 Init。

### B．已經進入正式帳號的 Windows 桌面

1. 接上網路，按 `Windows+E` →「本機／此電腦」→ USB → `windows_setup`。
2. 直接雙擊 `windows.cmd`，沿用目前帳號；不需要先執行 Init。SSH 包含在 Windows 第 4 階段。

### 接著套用設定

1. 登入正式帳號後，雙擊完整工具包的 `windows.cmd`。依提示允許權限、輸入目前帳號密碼；不裝驅動時，在選包提示輸入 N 或按 Enter 略過（只有型號完全對上時 Enter 才是安裝，見〈準備獨立驅動包〉）。
2. 等整輪結束、查看結果後再手動重開機。從 USB 開啟 `windows_setup\core`，雙擊 `verify_after_restart.cmd` 續跑與驗收。
3. 處理畫面列出的失敗，再雙擊 `verify_only.cmd` 檢查，最後依[目視確認](#6-最後目視確認)核對桌面、工具列及顯示。

Windows 流程也會移除清單中的預載應用程式並變更系統設定；請先閱讀下方模組說明，確認符合需求。桌面清理會刪除一般桌面檔案，開始前先移走要保留的資料。套用 Windows 設定與驗收時使用正式目標本機管理員帳號。執行中保持 USB 連接。

找不到 USB 或需要命令列時，再展開下方的排錯說明；初始設定使用 `Shift+F10`；不必用 `diskpart`。

## 目錄

- [快速開始](#快速開始)
- [執行前提](#執行前提)
- [概覽與適用範圍](#概覽與適用範圍)
- [準備 USB](#準備-usb)
- [初始安裝操作](#先看目前在哪個階段)
- [模組與獨立執行](#模組補充說明)
- [SSH 與 hosts](#ssh-與-hosts-後續維護)
- [來源包準備](#從原始碼準備完整工具包)
- [架構與依賴](#專案架構與依賴方向)
- [CI 與本機測試](#windows-ci)
- [版本發布](#維護者版本發布)
- [目錄索引](#模組資料夾索引)

根目錄 README 是使用入口；[第三方來源與授權](doc/third_party.md)及[版本紀錄](doc/changelog/changelog.md)集中於 doc。agents.md 留在根目錄供維護者與工具明確讀取維護規範，不是一般操作說明；第三方 LICENSE 保持上游原位。

## 執行前提

- 預設自動選擇硬體設定檔：Intel NUC8i7HVB／NUC8i7HNB 使用 NUC8 設定檔；驅動包由你選擇；只有系統自動偵測到的型號與驅動包完全對上時，Enter 才會安裝，其餘情況 Enter 一律略過驅動安裝，AMD 模組依機型執行；其他主機板使用 Generic，略過這兩個硬體模組，其餘 Windows 設定照常執行。
- 64 位元 Windows 11 22H2 或更新，專業／企業／教育版；Windows 流程須在正式目標本機管理員桌面執行。
- 完整工具包必須可寫入，不能放在將被清理的桌面；使用者名稱與磁碟代號動態取得。
- 正式桌面需有 Windows Terminal（`wt.exe`）與 App Installer／WinGet（`winget.exe`）；缺少時前置檢查會中止，先補齊再重跑。
- Windows Update 與未快取的 OpenSSH 元件需要網路。UAC、密碼及提示的重新開機需使用者操作。`windows.cmd` 開頭的網路檢查只是提醒，與 SSH 設定無關：偵測到網際網路時直接繼續；否則輸入 R 可重新檢查，按 Enter 不等網路繼續。若 Windows Update 出現 0x8024402C，請核對 DNS 與代理設定及組織網路要求後重試，不要自行停用安全設定；SSH 或更新階段失敗時，連線後可分別執行 `modules\ssh\apply_ssh_settings.cmd` 或 `modules\updates\install_windows_updates.cmd` 重試該模組。
- 桌面清理會刪除一般桌面檔案、資料夾與捷徑；先取走要保留的內容。桌面排列範本以繁體中文、1920×1080、100% 縮放為準。

## 概覽與適用範圍

Git／GitHub 版本與目前本機完整包不同：驅動及 Autologon EXE 不納入 Git，從原始碼取得後須依 [來源包準備說明](#從原始碼準備完整工具包) 補齊再檢查。第三方來源及授權見 [第三方來源與授權](doc/third_party.md)。公開來源的網路 Sites 預設為空集合；請在本機維護個人規則。

本工具依上方前提自動選用 Generic 或 NUC8 設定檔，Windows 模組亦提供獨立入口。初始設定先執行 Init，登入正式帳號後直接執行 Windows；已有正式帳號可直接執行 Windows；不需要 agent、SSH 遙控或預先手動安裝 OpenSSH。使用者名稱、家目錄與 SID 由腳本動態取得；工具包位置依目前檔案所在目錄解析，不綁定固定帳號或磁碟代號。

本機維護的 `windows_setup` 主程式可複製到 USB；若根目錄有供開發使用的 `worktree`，複製時請排除該目錄，並保留主程式所需資產。Git 忽略規則不會自動排除檔案總管中的手動複製。也可由 Release 來源包開始準備。腳本依自己所在位置解析主程式，不綁定 Downloads、USB 磁碟代號或使用者名稱。驅動獨立放在 `windows_driver_packages/nuc8`，主程式不含驅動封存檔。每次換機使用前要確認 USB 是最新完整副本；舊 USB 不會自動同步本機修改。

完整流程需要你允許管理員權限、輸入現有帳號密碼，以及依提示手動重新開機，並非完全無人值守。一般 Windows 設定不自行重新開機或關機；OOBE 套用設定包前會先明確詢問，Windows 可能在同意後重新啟動。

## 準備 USB

先將完整主程式複製到可寫入的 USB，保持以下結構。主程式內所選功能需要的資產也要帶齊；如果使用 GitHub 原始碼下載，先完成 [來源包準備](#從原始碼準備完整工具包)，來源 ZIP 不含驅動及 Autologon EXE。

```text
USB 根目錄\
├─ windows_setup\
│  ├─ init.cmd
│  ├─ windows.cmd
│  ├─ readme.md
│  ├─ core\
│  └─ modules\              保留整份工具包，其餘檔案也一併複製
└─ windows_driver_packages\  可選；不需要 NUC 驅動可不帶
   └─ nuc8\                 保留 install.cmd、manifest、輔助腳本及十二個 ZIP
```

不是只複製兩個 `.cmd`。USB 必須可寫入，執行時保持連接，不可放到會被清理的桌面；`.git` 不是執行必要檔案。可以直接在 USB 使用，也可以自行完整複製到其他可寫入位置，無需固定任何使用者的 Downloads。

<details>
<summary>找不到 USB／需要命令列時</summary>

### 還在初始設定畫面：用 Shift+F10 找到 USB

1. 插上已放好完整工具包的 USB。按 `Shift+F10`（部分鍵盤需 `Fn+Shift+F10`），開啟黑色命令提示字元視窗。
2. 這裡是 **CMD，不是 PowerShell**。下面指令一次輸入一行再按 Enter；不要輸入畫面原有的 `C:\...>` 提示字元。
3. 依序輸入以下三行，查看磁碟清單：

```cmd
diskpart
list volume
exit
```

依 USB 的名稱與容量辨認其 `Ltr` 磁碟代號。這三行只查看清單，不會修改磁碟；最後的 `exit` 只退出 DiskPart，會回到 CMD。

4. 假設清單顯示 USB 是 **E:**，輸入以下三行；**E: 只是例子，必須換成你剛查到的代號**：

```cmd
cd /d "E:\windows_setup"
dir init.cmd windows.cmd
call init.cmd
```

`cd /d` 會一起切換磁碟與資料夾；`dir` 應列出兩個入口。請確認前兩行成功才執行第三行，這不是直接把所有指令一次貼上的步驟。

5. 依 Init 畫面提示繼續。缺少設定包時會在帳號建立前停止；完整工具包會先核對環境、資產與權限，再詢問必要帳密。套用前明確同意 Windows 可能重新啟動。

#### 找不到資料夾或 USB 沒有磁碟代號

若已確認 USB 是 E:，但 `cd /d` 顯示找不到路徑，先輸入：

```cmd
dir E:\
```

請確認根目錄有完整的 `windows_setup` 資料夾。若你放在其他位置，例如 `工具\windows_setup`，先用 `dir "E:\工具"` 查看，確認後改用 `cd /d "E:\工具\windows_setup"`，再執行 `dir init.cmd windows.cmd` 與 `call init.cmd`。每個 E: 都換成實際 USB 代號；只查看已確認的 USB，不必搜尋整顆硬碟。

若清單沒有 USB、USB 沒有 `Ltr`，或裡面根本沒有完整工具包，先重新插接或回另一臺電腦確認 USB 與資料夾；不要猜路徑，也不要為了找腳本而變更磁碟設定。整包結構依上方「準備 USB」，不是只帶一個 `init.cmd`。

</details>

### 已進入稽核或正式桌面：用檔案總管開啟 USB 腳本

1. 按 `Windows+E` 開啟檔案總管，左側選「本機／此電腦」，依名稱與容量找到 USB 並雙擊。
2. 打開 USB 裡的 `windows_setup`（若放在其他資料夾，就逐層打開），確認看得到 `init.cmd`、`windows.cmd`、`core`、`modules`。
3. 稽核桌面雙擊 `init.cmd`；正式帳號桌面直接雙擊 `windows.cmd`。若檔案總管隱藏副檔名，可能只顯示 `init` 或 `windows`；可在「檢視 → 顯示 → 副檔名」勾選後再辨認，不必先更改此設定才能執行。
4. 需要參數或想用命令呼叫時，在**這個資料夾的位址欄**點一下（或按 `Alt+D`），輸入 `cmd` 後按 Enter。開啟的 CMD 已位於工具包資料夾，先輸入 `dir init.cmd windows.cmd` 確認。

依目前階段只執行對應的一行，**不要將下面整段一次貼上**。入口會啟動 PowerShell 並在結束後保留視窗；只有本輪確實結束、畫面已有結果時，若看到 `PS` 提示字元，輸入 `exit` 返回原 CMD。尚在執行時不要輸入 exit 或關閉視窗。

```cmd
call init.cmd
```

上面的 Init 只在初始設定／稽核桌面準備帳號。登入正式帳號後，直接執行下面的 Windows 入口；不需再執行 Init：

```cmd
call windows.cmd
```

整輪完成並手動重開機後，自動登入進桌面就會自動執行重開後驗收（見[第 5 節](#5-重開機後自動驗收)），不需再找工具包。自動驗收停止或畫面提示未登記時，再按上述方式重新找到同一份工具包、開啟 CMD，執行：

```cmd
call windows.cmd -AfterRestart
```

完成續跑後，先離開保留的 PowerShell 回到 CMD，或重新從工具包位址欄開 CMD。只檢查現況使用：

```cmd
call windows.cmd -VerifyOnly
```

若使用本機完整副本，操作完全相同：先在檔案總管打開該資料夾，再從位址欄開 `cmd`，不需要知道或寫死使用者名稱。使用 PowerShell 者則在正確資料夾執行 `.\init.cmd`／`.\windows.cmd`，不要混用 CMD 與 PowerShell 的目錄切換語法。

重開機後 USB 磁碟代號可能改變，請重新從檔案總管確認、再依上述步驟開啟正確資料夾；不要照抄前一次磁碟代號。主程式與驅動包放在同一 USB、相對目錄保持不變時，續跑會用保存的相對位置及驅動包身分重新核對。若驅動包原本在另一個磁碟／USB，則不猜測新位置；舊路徑失效時，從一般 `windows.cmd` 入口重新選包。不要刪除續跑紀錄來跳過失敗。

## 先看目前在哪個階段

兩個入口各有用途：`init.cmd` 處理初始帳號與 OOBE；`windows.cmd` 處理正式帳號登入後的 SSH、驅動、更新、清理與偏好。不要在 OOBE 或稽核用 Administrator 桌面執行 windows.cmd。

### 情境 A：全新安裝，仍在初始設定／連接 Wi-Fi 畫面

依[快速開始 A](#快速開始)從 USB 的 `init.cmd` 執行。腳本要求 Windows 11 22H2 以上 x64 桌面版，使用官方唯讀 `OOBEComplete` 判斷初始設定，並拒絕 WinPE 與一般 SYSTEM 工作。帳號與密碼由你輸入；不重設或提升既有同名帳號。

設定包只包含 `HideOobe=True`，不含帳密或 Microsoft 工具。先建立並讀回確認正式管理員帳號，才會詢問是否套用；Windows 可能因套用設定包重新啟動，因此必須先輸入 `YES` 同意。腳本不會在 SYSTEM 下執行 Sysprep。

續跑檔案放在 `%ProgramData%\windows_setup_init`，只允許 SYSTEM 與管理員讀寫；同層的 `windows_setup_init.cmd` 是取消／中斷時的恢復入口，供一般使用者唯讀啟動提權。若在 OOBE 取消或中斷，按 Shift+F10 從完整工具包重新執行 `init.cmd` 繼續；設定包成功套用並正常登入後，執行完整工具包的 `windows.cmd`：它在設定前核對同一臺機器、目標 SID、家目錄、正式桌面及已安裝設定包，再記錄帳號確認。此紀錄不代表 SSH 已完成，SSH 由第 4 階段處理。帳密不保存在設定包或續跑 JSON；若帳號已建立但寫入所有權紀錄失敗，會保留帳號並停止，不會猜測接管同名帳號。

舊版 `SshPending`／`Complete` 紀錄通過相同核對後，會先保留受保護的 `state_before_account_confirmation.json`，再轉為 `AccountConfirmed`；不刪除舊執行檔案，也不把舊狀態當成目前 SSH 驗證結果。

Windows 更新等流程結束後依提示手動重新開機；自動登入後會自動執行重開後驗收（自動驗收停止時才手動執行 `windows.cmd -AfterRestart`），再用 `windows.cmd -VerifyOnly` 檢查。

### 情境 B：已有正式本機帳號，從 Windows 桌面開始

此情境保留現有帳號，不重新建立帳號。USB 與本機的完整工具包都可使用，不必先移到 Downloads。

1. 登入要套用設定的本機管理員帳號，確認記得現有密碼；先取走桌面要保留的檔案，接上網路並保持電源穩定。
2. 準備完整工具包：可以直接開啟 USB 的 `windows_setup`，或開啟自行完整複製到本機可寫入、非桌面位置的副本。依上方「已進入稽核或正式桌面」的步驟找到資料夾，再從位址欄開啟 CMD。
3. 直接執行 `windows.cmd`，允許目前帳號提權，依提示輸入現有密碼供自動登入使用。需要 NUC 驅動才選擇獨立包；型號沒有完全對上時按 Enter 會略過。等待整輪 19 個模組完成，不要中途關機。第 4 階段會安裝／啟用 OpenSSH Server、設定區域網路防火牆及目前使用者的 SSH／hosts 框架；缺網路或元件時會記錄失敗，連網後再重跑 Windows 或獨立 SSH 模組。
4. 整輪結束後手動重新開機，以同一帳號登入；此時可以拔除 USB。
5. 進入桌面後會自動開啟一個終端機執行重開後驗收，不需輸入。若仍要求重開，依提示手動重開，登入後會再自動驗收，最多 3 次。自動驗收停止時，插回同一份工具包（重新確認磁碟代號）執行 `.\windows.cmd -AfterRestart`。
6. 處理所有失敗後執行 `.\windows.cmd -VerifyOnly`，再逐項完成下方「最後目視確認」。有錯誤時查看 `reports` 及畫面，不將舊結果當成本輪成功。

兩種情境都由目前正式使用者與腳本位置解析路徑，不要求固定帳號、磁碟代號或家目錄；請勿使用另一位管理員的帳密代替目前使用者提權。SSH 由 Windows 第 04 模組執行，也可單獨使用 `modules\ssh\apply_ssh_settings.cmd`。

以下是正式帳號桌面的後續流程。已完成上方 Init 的使用者，不必再建立帳號；直接確認前提並從步驟 2 繼續。

## 1. 完成 Windows 初始設定

1. 進入 Windows 桌面，登入之後要長期使用的本機管理員帳號。
2. 設定並記住該帳號的現有密碼。帳號可自行命名；自動登入會使用目前帳號，不會要求所有電腦使用同一組帳密。
3. 接上網路並保持電源穩定。完整流程需要下載 Windows Update 與尚未安裝的 OpenSSH 元件。
4. 多臺電腦請先各自設定唯一電腦名稱，例如 `NUC-001`、`NUC-002`；名稱變更要求重開時先完成重開，再開始下列流程。
5. 取走桌面上需要保留的資料。桌面清理模組會刪除使用者桌面及共用桌面的普通檔案、資料夾和捷徑，最後只留下四個系統圖示。

## 2. 確認 USB 工具包與可選驅動

已按「準備 USB」完成者，繼續使用同一份 USB 工具包，不必再複製到本機。以下是主程式的完整結構概覽：

```text
windows_setup\
├─ init.cmd                    初始帳號／OOBE
├─ windows.cmd                 正式帳號桌面設定
├─ readme.md                   本文件
├─ core\                      主流程、驗證與路徑表
├─ drivers\                   機型 profile／manifest 與官方版本說明（不含 ZIP）
├─ modules\                   每個功能自己的腳本、資產與獨立入口
│  ├─ init\                   OOBE 帳號初始化與正式登入續跑
│  ├─ ssh\                    SSH 及 hosts 同步
│  ├─ drivers\                共用驅動安裝引擎與驗證
│  ├─ updates\                Windows Update
│  ├─ debloat\                清理與 Win11Debloat
│  └─ …                        帳號、記憶體、電源、桌面、輸入法等
├─ reports\                   本機整體進度、結果與紀錄（不納入 Git）
├─ test\powershell\          unit／integration 分層測試
└─ doc\changelog\            版本摘要與紀錄規範
```

驅動包獨立於主程式。執行 `windows.cmd` 先顯示偵測主機板：一般電腦自動略過 NUC 驅動；支援 NUC 才提示選包。找到相鄰 `windows_driver_packages/nuc8` 時，會先唯讀核對身分（不計算大檔雜湊）：只有系統自動偵測到唯一型號、該型號完整列在驅動包與工具設定檔的支援清單（精確比對，不接受部分字串）、且架構與設定檔雜湊相符時，提示才寫「完全相符」，此時 Enter 或 Y 安裝、N 略過、P 指定其他位置；選用後仍會完整驗證 SHA256，失敗就不安裝。型號手動確認、無法偵測、有多塊板、型號不在清單或包內身分檔缺少／損壞時，Enter 一律略過，並用一句話說明哪裡沒對上；手動確認型號仍可輸入 Y 明確選用。略過時會顯示「本次不安裝驅動」；之後要補裝，重新執行 `windows.cmd` 並選用驅動包（`-AfterRestart` 續跑不會重新詢問）。無法辨識的輸入不會當作同意，會重新詢問。找不到相鄰包時 Enter 仍是略過。找不到包或包校驗失敗時，可輸入正確目錄或 Enter 略過；也可明確傳入：

```powershell
$driverPath = Read-Host '貼上目前獨立驅動包 nuc8 的完整路徑（不用加引號）'
.\windows.cmd -DriverPackagePath $driverPath
```

偵測失敗或板號空白／明確未知時，選 R 重新偵測、G 或 Enter 使用通用設定，或依下表選擇實際 NUC 整機，再輸入完整板號確認。回報已知其他板號、同時回報多塊板，或重新偵測與確認不符時，不允許強制套用 NUC 驅動。手動確認只影響驅動；AMD 位置設定仍只依自動偵測。原始板號、偵測錯誤與確認值分開保存在該機 reports。獨立包可自行執行 `install.cmd`；只核對完整性用 `install.cmd -PackageOnly`。獨立安裝器使用相同偵測與未知型號確認流程；已知其他機型略過，不能拿 NUC 驅動套用其他硬體。`-PackageOnly` 是離線驗包，不可與手動確認參數混用。續跑只沿用同一電腦與使用者先前明確選擇的驅動包，並核對 package.json／manifest.json 的雜湊；同 USB 相對位置可隨盤符變動解析，包身分變更則拒絕。整包複製至其他電腦不沿用舊選擇。

`-NonInteractive` 關閉驅動選擇及舊版開始選單政策的詢問，並不代表 Windows 全流程無人值守；自動登入等模組仍可能詢問密碼。無互動主控台時也不等待驅動輸入，未選包即略過。需自動化處理「未知」且已人工確認的實機時，可明確傳入 `-ConfirmedBoard NUC8i7HVB -ConfirmationComputer $env:COMPUTERNAME -DriverPackagePath $driverPath -NonInteractive`（HNK 使用 HNB）；已知其他機型仍拒絕。`windows.cmd -VerifyOnly`／`-AfterRestart` 不接受新的型號或包選擇，只恢復同機同帳號紀錄；重新選擇請走一般入口。明確傳入空路徑表示略過，未提供路徑才允許互動選包。

不要只複製單一 `.cmd`／`.ps1`；主程式與獨立驅動包各自保留完整結構。`.git` 僅在維護版本時需要，執行設定與獨立驅動包不依賴它。
工具包不要放在桌面或其子資料夾內，以免桌面清理刪到工具包。直接使用 USB 時，USB 必須可寫入且本輪全程保持連接；下一輪仍從同一完整副本續跑。若自行改用本機完整副本，才改從本機該份執行。

腳本不會自行把工具包複製到 Downloads，也不會自動同步其他副本。要更新別臺電腦時，由你選擇要複製的完整主版本；先保留目的地的自訂檔及需要的執行紀錄，避免直接覆蓋。

### 獨立驅動包的明確適用型號

主工具的通用 Windows 設定不限定 NUC；下表只限制可選 NUC 驅動包與目前 NUC AMD 模組。

| 整機／套件型號 | 官方 BIOS 主機板識別 | 腳本接受的 Win32_BaseBoard.Product |
| --- | --- | --- |
| Intel NUC8i7HVK（同板整機：NUC8i7HVKVA、NUC8i7HVKVAW） | NUC8i7HVB | `NUC8i7HVB` |
| Intel NUC8i7HNK（同板整機：NUC8i7HNKQC） | NUC8i7HNB | `NUC8i7HNB` |

型號對照依 [ASUS 官方 NUC 規格索引](https://zentalk.asus.com/t5/faq/nuc-technical-product-specifications-for-nuc-products/ta-p/451363)；HVK／HVB 亦見 [Intel 技術規格](https://www.intel.com/content/dam/support/us/en/documents/mini-pcs/nuc-kits/NUC8i7HVK_TechProdSpec.pdf)。官方表列的是 BIOS 識別，腳本實際讀取 SMBIOS 主機板 Product，去除首尾空白後比對白名單；不依外殼貼紙猜型號，也不表示所有 NUC8 都支援。可先執行 `(Get-CimInstance Win32_BaseBoard).Product` 查看。已知非白名單值會安全略過；只有空白／明確未知或讀取失敗才提供受控手動確認，確認不會覆寫報告中的原始偵測值。

這是型號對照與安裝條件，不代表每個整機變體已實測。目前清單為十二包、33 個 INF 目標及一個 Extension，精確版本與依賴見 [機型設定檔](drivers/nuc8i7hvk_hnk/readme.md)；仍依裝置枚舉結果與 Windows Update 處理其他驅動。AMD 封存檔 GFX-Radeon-Win10-23.10.01.46.zip 在官方列為 Windows 10 64-bit，不能宣稱 Windows 11 官方認證；本工具在 Windows 11 的結果須逐機驗證。 驅動來源見 [ASUS NUC8i7HVK 下載頁](https://www.asus.com/uk/supportonly/nuc8i7hvk/helpdesk_download/)。

## 3. 執行第一次設定

1. 在正式目標帳號桌面，從同一 USB 雙擊 `windows.cmd`；不要使用稽核模式的 Administrator。
2. Windows 管理員權限提示選「是」。請用目前登入的目標帳號執行，不要輸入另一個管理員帳號代替。
3. 依提示輸入目前帳號的現有密碼，用來設定開機自動登入。密碼不會寫入工具包腳本。
4. 等待視窗中的 19 個模組執行完畢。進度與結果以中文顯示；Windows Update 可能需要較久。

執行期間不要關閉主視窗、移動工具包、關機或提早重開機；若從外接磁碟執行，不要拔出該磁碟。即使畫面顯示某一個模組完成，也要等整輪結束。

若有錯誤，記下模組名稱與訊息，並查看工具包內的 `reports\Setup-Result.json`。腳本可能繼續後面的模組，因此「本輪執行結束」不一定代表所有模組成功。進度可查看 `reports\Setup-Progress.json`；更新進度可另開 `modules\updates\show_update_status.cmd`。

如果在最前面的 UAC 政策／帳號密碼／自動登入階段就中止，這個失敗不會加入後續模組重試清單；先修正密碼或畫面指出的問題，再執行 `windows.cmd`。不要把上次留下的結果檔當成本輪已完成。

## 4. 等整輪結束後手動重新開機

主視窗完成全部階段後，會提示已登記重開後自動驗收，再由 Windows 電源選單選「重新啟動」。這時可以拔除 USB：結束前已把續跑必需的檔案（`core`、`modules`、根目錄入口與驅動設定檔／清單，不含驅動封存檔、維護工具與文件）複製到本機 `%ProgramData%\NUC8-Setup\resume`，只允許 SYSTEM 與管理員存取，並記錄來源版本與逐檔 SHA256。這份複本只供重開後驗收使用，不取代工具包，也不綁定磁碟代號；驗收完成後會自動清除。

若畫面改顯示「未登記重開後自動驗收」及原因，請保留工具包，重開後依第 5 節的手動入口執行。

第一次設定完成後仍應重新開機一次，讓登入後設定生效，不要只因更新沒有標示待重開機就跳過這一步。

重新進入桌面時，確認是否自動登入正確帳號。如果沒有自動登入，先手動登入原本同一個帳號並記下現象，不要換帳號繼續。

## 5. 重開機後自動驗收

1. 以同一帳號自動登入進入桌面約 30 秒後，會自動開啟一個 PowerShell 終端機執行重開後驗收，內容與 `windows.cmd -AfterRestart` 相同：重試同一臺電腦、同一帳號先前失敗且可重試的模組，重新掃描更新，再做清理及驗證。不需輸入資訊，也不另跳 UAC 或其他視窗；請等待本輪結束，不要關閉該視窗。
2. 開始前先核對本機複本：同一臺電腦、同一帳號，且清單與每個檔案的 SHA256 都和登記時相同。不符就停止並說明哪個檔案，移除自動執行登記，保留複本供檢查。
3. 驅動包不在時（例如 USB 已拔除），驅動驗收改讀本機已安裝驅動：裝置無異常、版本符合已核清單即通過，找不到驅動包不算失敗；若仍需安裝驅動，會提示插回驅動包手動執行。驅動包仍在原位置且身分相同時，維持完整 SHA256 與 INF 核對。
4. 報告寫在本機 `%ProgramData%\NUC8-Setup\reports`，不寫 USB。通過且沒有待重新開機提示時，自動移除登記與本機暫存，只保留報告。仍需重新開機（Windows 要求重開、分頁檔待生效、工作列或開始選單待下次登入）時保留登記並提示；手動重開並自動登入後會再自動驗收，最多 3 次，超過就停止並說明。不是重開可以解決的失敗也會停止自動執行。
5. 直到顯示驗收通過、沒有未解決失敗，也沒有待重新開機提示，再做下面的目視確認。

手動入口保留：自動驗收停止、或一鍵流程結束時提示未登記，就開啟同一份工具包（重新確認 USB 磁碟代號與終端所在位置），在此資料夾執行 `.\windows.cmd -AfterRestart`，也可雙擊 `core\verify_after_restart.cmd`；若仍要求重開，等本輪結束後手動重開再執行一次。手動入口的報告寫在工具包的 `reports`。

更新可能分成多輪。若相同錯誤持續出現，不要只靠一直重跑；查看報告位置中 `Acceptance-Result.json` 的 `Errors`／`FailedChecks`、`Verification-Result.json`、自動驗收的 `AfterRestartResume-Result.json` 及畫面訊息。另一臺電腦的舊結果不代表目前這臺成功。

如果只是想檢查現況，在此資料夾的終端執行 `.\windows.cmd -VerifyOnly`（或雙擊 `core\verify_only.cmd`）；它不安裝更新或重新套用偏好。若開始選單驗證顯示工作尚未回傳結果，先等該工作結束，再重新驗證。

## 6. 最後目視確認

- 開機自動登入的是正確帳號。
- 解析度為 `1920×1080`，縮放為 Windows 標準 `100%`，不是自訂縮放。
- Windows 與應用程式使用深色模式，桌面背景是純黑色。
- 桌面只顯示控制台、本機、網路、資源回收筒，位置符合範本。
- 工作列啟用自動隱藏，只釘選 Edge，搜尋欄、天氣／小工具與工作檢視按鈕隱藏。執行中的其他程式仍可能顯示在工作列。
  自動隱藏使用 [Windows AppBar API](https://learn.microsoft.com/en-us/windows/win32/shell/abm-setstate)，在目前互動使用者的工作階段立即套用及讀回；獨立執行 `modules\taskbar\apply_taskbar_settings.cmd` 也會套用，`-VerifyOnly`／重開後檢查會重新讀取目前狀態。找不到該工作階段的工作列或讀回不符時明確失敗，不覆寫整段登錄資料。
- 開始選單釘選清空；按 Windows 鍵仍可搜尋程式。
- 檔案總管顯示一般隱藏項目與副檔名；受保護的系統檔仍保持隱藏。
- 預設輸入為英文美式鍵盤，需要中文時按 `Win+Space` 切換。
- 按 `Ctrl+Alt+T` 能開啟 Windows Terminal。
- NUC8 設定檔：AMD Software 不再於登入時詢問位置權限；Generic 不套用此模組。如果舊提示已經顯示在畫面上，先手動關閉該提示，再於下次登入確認。

四個桌面圖示的排列範本以繁體中文 Windows、1920×1080、100% 縮放為準。自動檢查不能取代上述登入與畫面觀察。

## Windows Update 進度與紀錄

更新階段使用 Windows Update API 回報的下載／安裝百分比，包含目前第幾項、總項數、標題與單項進度。背景工作每約 5 秒更新進度檔，主視窗每約 15 秒顯示狀態及最後回報時間。掃描階段只有狀態與經過時間，不以時間估算百分比；掃描尚未返回時，最後回報時間可能暫時不變。Windows「設定」頁面不一定會呈現這個 API 工作的相同進度，請以工具視窗及本輪紀錄為準。

可另外以系統管理員身分開啟 PowerShell 查看目前狀態：

```powershell
$state = Join-Path $env:ProgramData 'windows_setup_update'
Get-Content (Join-Path $state 'Update-Progress.json') -Raw -Encoding UTF8 | ConvertFrom-Json | Format-List
```

持續查看最新一份更新日誌（按 `Ctrl+C` 只停止觀看，不會中止更新）：

```powershell
$state = Join-Path $env:ProgramData 'windows_setup_update'
$log = Get-ChildItem -LiteralPath $state -Filter 'WindowsUpdate-*.log' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($log) { Get-Content -LiteralPath $log.FullName -Encoding UTF8 -Tail 30 -Wait }
```

新版 SYSTEM 更新工作使用 `%ProgramData%\windows_setup_update` 專用受保護目錄，只允許 SYSTEM 與管理員存取。複製前會檢查路徑、擁有者及 ACL，複製後核對所有執行來源的 SHA-256；已有不可信或 junction 目錄會停止，不接管或刪除它。舊 `%ProgramData%\NUC8-Setup\WindowsUpdate` 紀錄保留原位。新版驗證只接受與受保護 context 的電腦、原啟動帳號及本輪 ID 相符的結果；舊格式若缺這些資訊，會要求重新執行更新，不能當作本輪已通過。

`WindowsUpdate-Result.json` 保存搜尋結果碼／警告、下載結果碼／HResult、每項安裝結果及是否需要重新開機。只有搜尋與下載結果碼 `2`（完整成功）才繼續；失敗或部分成功不會當作「沒有更新」。結果檔、進度檔與 `WindowsUpdate-*.log` 都位於上述 `$state`；主流程另有工具包內 `reports\Setup-*.log`。

下載與安裝各自預設等待上限為 50 分鐘，逾時先記錄失敗並請求中止。Windows API 的清理可能仍需等待，不代表收到中止請求就已停止；請查看最後回報與日誌，不要因此連續重跑或關機。若同一排程仍在執行，工具會拒絕重啟及覆寫 worker。本工具不自動重新開機。

介面依據：[Microsoft BeginDownload](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdatedownloader-begindownload)、[BeginInstall](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdateinstaller-begininstall)、[非同步操作與清理](https://learn.microsoft.com/en-us/windows/win32/wua_sdk/guidelines-for-asynchronous-wua-operations)。
## 管理員提權提示與還原

`windows.cmd` 第 1 階段會把這臺電腦的 `ConsentPromptBehaviorAdmin` 設為 `0`：此電腦的管理員之後提權會自動核准，不再顯示「是否允許此應用程式變更您的裝置」。第一次啟動腳本仍須核准一次。這會降低管理員操作的提示防護；不影響標準使用者的提權規則，也不關閉 UAC、Defender 或 SmartScreen。

在工具包根目錄可單獨執行：

```cmd
modules\uac\apply_uac_settings.cmd
modules\uac\apply_uac_settings.cmd -VerifyOnly
modules\uac\apply_uac_settings.cmd -Restore
```

模組要求原有 `EnableLUA` 為 DWORD `1`，否則停止並要求先人工確認，不順便修改它或安全桌面政策。首次執行會在 `%ProgramData%\NUC8-Setup\UAC-Original.json` 保存這臺電腦的原值與是否存在；重跑不覆寫。`-Restore` 只還原這份原值（原先不存在則移除該值），不保證還原後一定顯示提示；不要刪除原值檔或拿其他電腦的檔案覆蓋它。

每次都讀回政策確認，組織政策覆寫或錯誤會回報失敗。結果在 `%ProgramData%\NUC8-Setup\UAC-Result.json`；`windows.cmd -VerifyOnly` 也核對本輪結果。還原後，針對一鍵流程的「管理員免提示」驗證可能不通過，這代表目前採用還原的設定。

政策值依據：[Microsoft UAC 設定及組態](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/user-account-control/settings-and-configuration/)。
## 休眠與快速啟動

`windows.cmd` 第 3 階段除了把插電時的自動睡眠／休眠逾時設為永不，也會執行 `powercfg /hibernate off` 停用休眠：

- 系統磁碟的 `hiberfil.sys` 會移除，大小通常是實體記憶體的一定比例（數 GB），可釋放磁碟空間。
- 快速啟動依賴休眠，會一併停用。關機改為完整關機，冷開機可能比原本稍慢；重新開機與手動睡眠不受影響。
- 雙系統環境中，快速啟動會讓 Windows 的 NTFS 分割區停在休眠狀態，另一個作業系統掛載時可能只能唯讀或有資料不一致風險；停用後分割區會正常卸載。

在工具包根目錄可單獨執行：

```cmd
modules\power\apply_power_settings.cmd
modules\power\apply_power_settings.cmd -VerifyOnly
```

套用後讀回 `HKLM\SYSTEM\CurrentControlSet\Control\Power` 的 `HibernateEnabled`（沒有時採用 `HibernateEnabledDefault`），須為 DWORD `0`，且 `hiberfil.sys` 已不存在；`powercfg` 失敗或被組織政策覆寫時回報失敗。`-VerifyOnly` 只讀取這兩項，不修改設定。結果在 `%ProgramData%\NUC8-Setup\Power-Result.json`；`windows.cmd -VerifyOnly` 與重開後驗收也核對本輪結果。

本工具目前沒有休眠的 `-Restore` 入口。之後若要重新啟用休眠，以系統管理員身分開啟終端機執行：

```cmd
powercfg /hibernate on
```

`hiberfil.sys` 會重新建立；快速啟動是否恢復取決於「控制台 > 電源選項 > 選擇電源按鈕的功能」中的設定，本工具不修改該設定。重新啟用後，一鍵流程的「休眠停用」驗收會不通過，這代表目前採用自行啟用的設定。

## 自動登入停用與還原

`windows.cmd` 第 1 階段以 Microsoft Autologon 設定目前帳號開機自動登入，密碼由 Autologon 以 LSA 機密保存。電腦改變用途、轉交他人或不再需要自動登入時，在工具包根目錄執行：

```cmd
modules\accounts\apply_autologon_settings.cmd -Restore
```

`-Restore` 只取消自動登入，不需要輸入密碼，也不執行 Autologon：將 `Winlogon` 的 `AutoAdminLogon` 設為 `0`，若有明文 `DefaultPassword` 則移除，並刪除 LSA 儲存的 `DefaultPassword` 機密。`DefaultUserName` 與 `DefaultDomainName` 保留，登入畫面可能仍預先帶入該帳號。工具不保存也不還原套用前的自動登入狀態；原本已用其他方式設定自動登入的電腦，執行後同樣變成停用，需要時請自行重新設定。

完成後會讀回上述三項；任一項仍存在、被組織政策或其他工具改回，或無法查詢 LSA，都會回報失敗，不宣稱成功。結果寫在 `%ProgramData%\NUC8-Setup\Autologon-Result.json`，不含密碼。登錄值改變後仍需重新開機，才能確認實際已不再自動登入。

之後執行 `windows.cmd -VerifyOnly` 時，只有這份結果是同一電腦、同一帳號的成功還原，且本輪重新讀回仍為停用，「自動登入設定」才會標示為略過；否則仍為未通過。要再次啟用，請重新執行 `modules\accounts\apply_autologon_settings.cmd` 並輸入密碼。

機密依據：[Microsoft 保護自動登入密碼](https://learn.microsoft.com/en-us/windows/win32/secauthn/protecting-the-automatic-logon-password)。

## 非必要資料分享與隱私設定

`windows.cmd` 會在原本的 Win11Debloat 清理階段末端套用下列隱私政策，主流程仍是 19 個階段。也可在工具包根目錄單獨執行；CMD 會沿用目前帳號並要求必要的管理員權限：

```powershell
.\modules\privacy\apply_privacy_settings.cmd
.\modules\privacy\apply_privacy_settings.cmd -VerifyOnly
```

| 項目 | 套用結果 |
| --- | --- |
| Windows 診斷資料 | Pro／Pro for Workstations 使用最低支援的「必要」級別 1；Enterprise／Education 使用支援的關閉級別 0 |
| 廣告識別碼 | 停用跨應用程式廣告 ID |
| 診斷資料個人化推薦 | 對目前執行帳號停用以診斷資料提供個人化推薦 |
| 活動歷程 | 停用活動摘要、發布及上傳 |
| 回饋提示 | 不顯示 Microsoft 回饋邀請 |
| 線上語音辨識 | 停用 Microsoft 雲端語音辨識，因此 **Win + H 雲端聽寫也會受影響**；不是禁止所有麥克風使用 |
| 手寫與輸入改善 | 不傳送手寫及打字資料供改善辨識服務 |

Home 或無法辨識／未支援的版本會明確回報 `Unsupported`，不寫入政策，也不會標為通過。每次會逐項核對九個登錄政策值及 DWORD 型別；讀回不符、權限錯誤或寫入未生效均視為失敗。結果保存於 `%ProgramData%\NUC8-Setup\Privacy-Result.json`。`-VerifyOnly` 只讀政策並更新診斷結果，不重新寫入政策；`windows.cmd -VerifyOnly` 也會檢查本輪隱私結果，不能拿舊報告代替。

這些設定不代表電腦完全不傳送資料：專業版仍有必要診斷，Windows Update、安全服務，以及 Edge、Office 或其他應用程式也各有自己的資料控制。本模組不關閉 Defender、Windows Update、防火牆，不加入安全例外，不封鎖遙測網域，也不一概停用相機、麥克風等應用程式權限。

政策與支援範圍依 Microsoft 官方文件：[Windows 診斷資料級別](https://learn.microsoft.com/en-us/windows/privacy/configure-windows-diagnostic-data-in-your-organization)、[廣告 ID／語音／活動政策](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy)、[個人化推薦與回饋提示](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience)、[手寫及輸入資料分享](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-textinput#allowlinguisticdatacollection)。這是政策設定與讀回檢查，並非封包監測結果。

### 開始選單政策與待處理狀態

第 11 階段準備開始選單設定。支援新版政策的 Windows 使用 GPO；較舊的 Windows 11 22H2／23H2 或尚未具備該政策的版本使用隨包附帶的獨立開始選單設定包，沒有提高 Windows 最低版本。

舊版設定包是整臺電腦的政策，會在每次登入重新清空釘選。主流程先跑完全部 19 階段與最後檢查；只有其他步驟和裝置沒有錯誤，才詢問是否套用。Windows 可能要求重新登入或重新啟動，必須明確輸入 `YES` 才安裝；拒絕、非互動執行或其餘步驟失敗會保留 `LegacyPendingApply`，不會偷裝或自行重新啟動。

稍後要處理尚未套用的政策，先確認其他工作已完成，再從工具包根目錄執行：

```cmd
modules\start_menu\apply_start_menu_settings.cmd -ApplyPolicy
```

政策已準備但尚未由原生匯出確認空白時，結果為 `PendingSignIn`，不是已清空。待處理項目列在 `Setup-Result.json` 的 `PendingModules`，與真正失敗的 `StageErrors` 分開。手動重新登入後執行 `windows.cmd -AfterRestart`；此入口只驗證開始選單，不安裝其設定包。只有原生匯出確認零釘選才是 `Confirmed`，續跑會移除已確認的待處理項目。

## 19 個模組的執行順序

| 順序 | 處理內容 |
| --- | --- |
| 01 | 此電腦管理員提權免提示、目前帳號開機自動登入 |
| 02 | 停用磁碟分頁檔（虛擬記憶體） |
| 03 | 插電時停用自動睡眠／休眠逾時；停用休眠、移除休眠檔並一併停用快速啟動 |
| 04 | OpenSSH Server、區域網路防火牆、SSH 目錄與 hosts／SSH 同步框架 |
| 05 | Windows Update 建議更新 |
| 06 | 已選機型獨立包的驅動檢查與更新；未選包或 Generic 顯示略過 |
| 07 | NUC8 拒絕 AMD Software 位置存取；Generic 顯示略過 |
| 08 | Win11Debloat、OneDrive 與可移除的預裝 App 清理 |
| 09 | 獨立版 Copilot 清理 |
| 10 | 工作列自動隱藏、顯示與 Edge 釘選 |
| 11 | 開始選單釘選與推薦清理 |
| 12 | 1920×1080、原生 100% 縮放 |
| 13 | 桌面清理與四個系統圖示 |
| 14 | 深色模式與純黑背景 |
| 15 | 自動補齊英文（美國）與美式鍵盤，並設為預設 |
| 16 | Ctrl+Alt+T 開啟 Terminal |
| 17 | 顯示一般隱藏項目與副檔名 |
| 18 | 清除符合條件的舊系統／預設資料夾殘留 |
| 19 | 最後套用桌面圖示排列 |

驅動排在 Windows Update 之後，再套用畫面及工作列設定，避免更新顯示驅動後覆寫設定。初次整輪最後會重新盤點已選官方驅動目標；重開續跑先核對同機、同帳號與允許的失敗模組，再執行更新及驅動唯讀盤點。版本已達標或較新便不重新解壓安裝；需要更新才安裝，驅動未核正常時保留畫面重試，最後仍重新驗證。不會自動重新開機。

第 15 模組會在缺少時新增英文（美國）`en-US`，並確保存在美式鍵盤 `0409:00000409`，再設為預設輸入法；保留中文、其他語言、既有鍵盤與順序，不安裝英文顯示語言包或切換 Windows 介面語言。若只要補英文鍵盤，可雙擊 `modules\input\apply_input_method_settings.cmd`；只檢查可在工具包目錄執行 `modules\input\apply_input_method_settings.cmd -VerifyOnly`。檢查會同時確認英文語言、美式鍵盤及預設輸入法，結果寫入 `%ProgramData%\NUC8-Setup\InputMethod-Result.json`。

各模組資料夾內另有獨立 `.cmd` 入口，例如 `modules\input\apply_input_method_settings.cmd`，詳見下方模組補充說明。不要因某一模組失敗就手動更動其他無關模組。

## SSH 與 hosts 後續維護

第 04 模組會建立目前使用者的設定與中文說明：

- `%USERPROFILE%\.ssh\readme.md`：SSH 連線別名、帳號、連接埠等用途與修改方式。
- `%USERPROFILE%\.config\hosts\readme.md`：網路規則及 hosts 對照來源的用途與修改方式。

hosts 設定資料夾保留在 `.config\hosts`，不改成 `.hosts`。Windows 系統 hosts 仍是 `%WINDIR%\System32\drivers\etc\hosts`。

SSH 與 hosts 可獨立或配合使用。這套工具目前提供可修改的網路規則與空白主機範本，不會自行填入真實主機 IP、遠端帳號或 SSH 私鑰。需要時依資料夾內 README 編輯；`active-sites.conf` 是自動產生的載入清單，不要手動修改。既有自訂 README 會保留。

## 範圍、版本與結果紀錄

Windows 啟用由使用者另外處理；本工具不處理 Ubuntu 分割或安裝。Windows 不允許移除的系統元件會保留，清理數量會隨 Windows 狀態而不同。

非繁體中文系統略過既有桌面圖示座標範本，但仍處理系統圖示 GUID。硬體或語系不適用項目明確顯示 Skipped，不計為通過；其他語系的電源解析等仍可能需要實機調整。請以目前這臺電腦的驗收結果為準，不保證不同 Windows 版本、硬體或螢幕得到完全相同的更新版本及刪除數量。

使用者可見的修改見 [變更紀錄](doc/changelog/changelog.md)；詳細驗證結果與限制以中文 Git 提交及 GitHub Release 說明記錄。工具包內已建立本機 Git，但執行設定不需要安裝 Git；若要查看歷史，可在工具包目錄執行 `git log -5 --oneline`。每機執行結果不納入 Git，請保留需要的診斷紀錄。

## 模組資料夾索引

| 資料夾 | 用途 |
| --- | --- |
| `modules\init` | 初始帳號建立 |
| `modules\accounts` | 自動登入、停用還原 |
| `modules\uac` | 管理員提權免提示、原值還原 |
| `modules\memory` | 分頁檔 |
| `modules\power` | 電源與睡眠 |
| `modules\ssh` | SSH 與 hosts 同步 |
| `modules\drivers` | 驅動 |
| `modules\amd` | AMD 位置權限 |
| `modules\updates` | 更新與進度 |
| `modules\debloat` | 預載 App、OneDrive、Copilot 清理 |
| `modules\taskbar` | 工作列 |
| `modules\start_menu` | 開始選單 |
| `modules\display` | 解析度與縮放 |
| `modules\desktop` | 桌面圖示與排列 |
| `modules\theme` | 深色與背景 |
| `modules\input` | 英文美式鍵盤 |
| `modules\terminal` | Terminal 快捷鍵 |
| `modules\explorer` | 隱藏檔與副檔名 |
| `modules\cleanup` | 舊系統與資料夾殘留 |

主流程結果位於 `reports`；整輪 `Setup-*.log` 開頭的「[驅動選擇]」記錄這次選包的分類（例如 Enter 略過、輸入 N、找不到包、型號未對上），「未知」表示沒有可信的選包結果，不等於略過。各模組的執行紀錄位於各自資料夾或畫面提示的 `%ProgramData%\NUC8-Setup`。電源模組的 `Power-Before-<時間>.txt` 與 `Power-After.txt` 也寫在這裡，不再寫入工具包；舊版已在工具包 `modules\power` 留下的同名檔案不會被自動刪除，它們屬於當時那臺電腦，確認不需要後可自行刪除，避免帶到其他電腦。既有程式碼不再全部平鋪在根目錄，請勿只取出其中一支腳本執行。

## 模組補充說明

### 各模組行為

1. Apply-AutologonSettings：以目前帳號設定自動登入；密碼透過 Microsoft Autologon 儲存，不寫在工具包腳本。`-Restore` 停用並清除儲存的密碼，見 [自動登入停用與還原](#自動登入停用與還原)。
2. Apply-PagefileSettings：停用磁碟分頁檔；重開機後完全生效。
3. Apply-PowerSettings：插電時停用自動睡眠和休眠逾時；停用休眠並移除 `hiberfil.sys`，快速啟動一併停用；保留螢幕逾時設定。詳見[休眠與快速啟動](#休眠與快速啟動)。
4. Apply-SSHSettings：安裝並啟用 OpenSSH Server；自動啟動，防火牆限制 LocalSubnet。
5. Install-WindowsUpdates：執行本輪 Windows 建議更新，顯示心跳進度並記錄是否需要重開機。
6. Install-Drivers：NUC8 且已選擇獨立包才核對機型與 SHA256 後安裝；未選包或 Generic 略過。異常裝置仍在驗收中檢查。
7. Apply-AMDPrivacySettings：NUC8 拒絕 AMD Software 地理位置存取；Generic 略過。已顯示的提示需手動關閉。
8. Apply-Debloat：先呼叫 remove_one_drive.ps1 解除安裝 OneDrive，再依 debloat_apps.txt 清理預裝 App，包含 Xbox App、Game Bar、相關登入與語音元件，以及存在時的 Gaming Services。Windows 不可移除的 XboxGameCallableUI 保留。
9. Apply-CopilotSettings：移除獨立桌面版 Copilot。
10. Apply-TaskbarSettings：隱藏搜尋、天氣/小工具與工作檢視；僅釘選 Edge。登入後自動解除暫時釘選原則。
11. Apply-StartMenuSettings：清空釘選、隱藏推薦及全部應用程式分類區；保留搜尋、帳號和電源。程式本體仍可搜尋啟動。
12. Apply-DisplaySettings：1920×1080、標準原生100%縮放，關閉自訂縮放。
13. Apply-DesktopSettings：清空普通桌面項目，顯示本機、網路、控制台、資源回收筒。
14. Apply-ThemeSettings：Windows/應用程式深色、純黑背景；必要時重新載入 Explorer。
15. Apply-InputMethodSettings：缺少時新增英文（美國）與美式鍵盤，再設為預設；保留中文及其他語言與鍵盤順序。Win+Space 切換，已開啟視窗可能保留原輸入法，下次登入使用新預設。驗證同時核對 en-US、美式鍵盤與預設值，不只檢查順序或 override。
16. Apply-TerminalHotkey：Ctrl+Alt+T 開啟 Windows Terminal，以一般使用者權限執行。使用 RegisterHotKey 背景監聽程式，登入時透過 Startup 自動啟動。

17. Apply-ExplorerSettings：設定登錄值與 Shell 即時狀態，重新整理已開啟的檔案總管以顯示一般隱藏檔；受保護系統檔保持隱藏。

18. Remove-SetupResidue：清除空的 Windows.old、預設聯絡人/遊戲等空資料夾及具名預設捷徑；含有其他資料時保留並記錄。

19. Desktop-IconLayout：最後套用四個圖示座標，避免先前的檔案總管重新整理影響排列。重開驗收入口也會最後套用此範本。

### 額外入口與快捷鍵排錯

- modules\desktop\save_desktop_layout.cmd：圖示移動後，將目前位置儲存成新範本。
- modules\updates\show_update_status.cmd：查看更新進度；關閉進度視窗不會停止更新。
- windows.cmd -VerifyOnly：檢查設定、目前顯示比例、圖示座標、開始釘選匯出、App清理、輸入法及快捷鍵程序。
- Terminal 快捷鍵日誌：%LOCALAPPDATA%\NUC8-Setup\TerminalHotkey\status-<桌面工作階段編號>.log；每個桌面工作階段有自己的日誌。舊版 listener 仍執行時，驗收可能使用原本的 status.log。
  從 SSH 的工作階段 0 驗收時，若同一使用者有多個桌面而無法唯一判定，驗收會停止；請在要檢查的桌面執行。
  REGISTERED 表示成功註冊；LAUNCHED 表示收到按鍵並呼叫 Terminal；FAILED 1409 表示快捷鍵衝突，需要排查。

### 主機名稱與區域網路

- 第 4 階段會在 SSH 與 LAN Ping 就緒後，啟動 Windows 原生持續 mDNS publisher，公告目前系統名稱的 `主機名稱.local`、各作用中介面的 A／AAAA 與 SSH `_ssh._tcp` 22。名稱與使用者動態取得；DHCP／網卡變更會重新綁定，改電腦名稱後重新啟動即可沿用新名稱。獨立入口是 `modules\ssh\apply_mdns_settings.cmd`，加 `-VerifyOnly` 可唯讀檢查。
- 在**另一臺同網段電腦的 PowerShell**，先複製畫面的 `ping -4 '主機名稱.local'`，再試 `ssh -l '帳號' '主機名稱.local'`；IPv6 可另用畫面的 `ping -6`。若名稱解析失敗，先複製畫面的 IP 備援命令。多個 IP 會完整列出，單一備援範例優先選一般 IPv4。
- IPv6 `fe80::` 是 link-local；畫面保留本機的 `%介面索引`，從另一臺直連時，scope 必須改用**用戶端**該網段的索引，可在該臺執行 `Get-NetIPInterface -AddressFamily IPv6 -ConnectionState Connected` 查看；不能直接沿用伺服器的索引。優先使用名稱或 IPv4 備援可避免手動選 scope。
- publisher 使用受保護的本機來源快照與 SYSTEM 開機工作，拔除 USB 後仍持續運作，不需要 agent 或 Bonjour。驗證會讀回目前工作、來源、SYSTEM 程序、本輪 RunId、鮮活 heartbeat 與原生註冊狀態；失敗會讓模組與總驗收失敗。`Registered` 表示本機原生公告已註冊，`RemoteVerified` 保持 false；另一臺能否解析仍以你實際執行上述命令為準，不以本機 `LocalMatched` 冒充跨機成功。
- `.local` 通常限同網段；訪客網路、AP 隔離、跨 VLAN、用戶端不支援 mDNS 或網路政策可能阻擋 multicast。工具不覆寫 GPO、開 UDP 5353 防火牆孔、修改 hosts、改名或關閉 IPv6；名稱失敗時可使用畫面中的實際 IP 備援。既有名稱觀測仍可用 `Resolve-DnsName -NoHostsFile` 協助診斷，不把觀測當公告或跨機證明；參見 [Microsoft 的名稱解析說明](https://techcommunity.microsoft.com/blog/networkingblog/resolve-dnsname-vs-nslookup-in-windows/4483858)及 [mDNS 管理說明](https://techcommunity.microsoft.com/blog/networkingblog/mdns-in-the-enterprise/3275777)。
- 多臺電腦建議路由器固定 DHCP 租約；需要跨網段時使用區域 DNS，例如 nuc-001.home.arpa。
- 沒有寫入固定 IP、個人 SSH 私鑰、hosts 站點資料或其他人的 SSH config。


## 清理與網路規則補充

Win11Debloat 清理除了檢查已安裝與預佈建 App，還會逐項讀回 `debloat_profile.json` 所選功能的登錄型別及值，不把第三方程序退出 0 當成全部成功。目前十項功能包含建議、廣告、Bing 與部分 AI 設定；依上游 Windows build 適用範圍，不適用項目在結果中明列 `Skipped`，不宣稱已套用。清單中的 Microsoft.Copilot、Microsoft.GamingServices 與 Microsoft.Edge.GameAssist 另以精確套件身分處理已安裝和預佈建版本，仍以讀回結果判定成功；結果保存在 `%ProgramData%\NUC8-Setup\Debloat-Result.json`；`windows.cmd -VerifyOnly` 會重新讀回本輪狀態，不重新清理或套用設定。登錄讀回不代表所有資料傳輸停止或所有應用程式 AI 功能已移除。

OneDrive 獨立入口為 `modules\debloat\remove_one_drive.cmd`；解除安裝後僅清除空的預設資料夾，不刪除個人或雲端資料。清理模組對 Windows.old、Contacts、Saved Games、Favorites、Links、Searches 只清除符合空目錄條件的項目；含資料或連結時保留。具名預設 Bing 書籤、捷徑與內建搜尋定義可清除，其他自訂內容保留；不可移除及僅 Staged 的 Windows 元件不代表一般已安裝 App 未清理。

Hosts／SSH 獨立入口為 `modules\ssh\apply_hosts_sync.cmd`、`sync_hosts.cmd`、`sync_ssh.cmd`。目前使用者的 `.config\hosts\sites.json` 支援任意站點，透過 Outputs 分別啟用 Hosts／SSH；每 10 秒重新讀取來源，未變更不重寫。SSID 若受定位權限限制，可用 NetworkProfile 或 IPv4Cidr，不會強制開啟定位。框架沒有實際主機清單或私鑰；詳細範例保留在模組內 `modules\ssh\custom_hosts_sync\usage.txt` 與 SSH／hosts README。

`.ssh` 具有 Windows Hidden 屬性；啟用顯示隱藏項目時仍可看見。第 04 模組設定 LocalSubnet 的 IPv4／IPv6 Ping 入站規則，名稱解析與 Ping 分開驗證，沒有關閉防火牆。rsync、SSH-agent、Tab 補全及金鑰部署尚未納入。

## 來源包與完整工具包

### 主程式與可選驅動包

主程式 `windows_setup` 與 `windows_driver_packages/nuc8` 是兩個獨立資料夾。只做一般 Windows 設定時帶主程式即可；需要 NUC 驅動才另帶驅動包。主程式只提示相鄰標準目錄，仍須明確選擇才使用，並核對包身分與全部封存檔雜湊。

### 從原始碼準備完整工具包

以下可以從全新的 Release 下載開始，不使用任何既有 Downloads／USB 資產。準備電腦需要 Windows 與網路；此階段只準備檔案，不執行 Init、Windows 設定或 Autologon。

1. 開啟 [Releases](https://github.com/ycpss91255-lab/windows_setup/releases)，選擇要使用的版本，先閱讀該版本說明與已知限制。標示 **Pre-release** 的版本是預覽版，不能當作已完成實機驗收。展開該版本的 **Assets**，下載 **Source code (zip)**。
2. 在檔案總管對下載的 ZIP 按右鍵 →「全部解壓縮」。打開解壓後資料夾，直到同一層可看到 `init.cmd`、`windows.cmd`、`readme.md`、`core` 與 `modules`；這一層就是工具包根目錄。可將它重新命名為 `windows_setup`，保留完整內容，**不要直接在 ZIP 視窗內執行**。解壓與執行位置必須可寫入，而且不能是稍後會被清理的桌面。
3. 開啟 [Microsoft Sysinternals Autologon 官方頁](https://learn.microsoft.com/en-us/sysinternals/downloads/autologon)，按 **Download Autologon** 取得 `Autologon.zip`，另行「全部解壓縮」。從中找到 **`Autologon64.exe`**；不要選 `Autologon.exe` 或 `Autologon64a.exe`，這套工具使用 x64 版本。
4. 在 `Autologon64.exe` 按右鍵 →「內容」→「數位簽章」，選擇 Microsoft Corporation 的簽章並按「詳細資料」，確認顯示此數位簽章正常。若沒有簽章、不是 Microsoft 或驗證失敗，先停止，重新從官方取得並排查驗證問題，不要略過。將核對後的 **`Autologon64.exe`** 複製到剛才工具包根目錄的 **`modules\accounts`**，最終位置為 `windows_setup\modules\accounts\Autologon64.exe`；不用雙擊 EXE。
5. 執行前閱讀 [Sysinternals 官方授權條款](https://learn.microsoft.com/en-us/sysinternals/license-terms)及下載包內的授權說明。後續 `windows.cmd` 的自動登入模組會驗證 Microsoft 簽章，並以 `/accepteula` 呼叫 Autologon 接受條款；不接受條款時不要執行該模組或 Windows 一鍵流程。下載與複製檔案本身不會設定自動登入，也不會執行 EXE。
6. 回到工具包根目錄，在檔案總管的**位址欄**輸入 `cmd` 後按 Enter。黑色命令視窗會從這個資料夾開始；貼上以下一行並按 Enter，執行既有的只讀套件檢查：

   ```cmd
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\core\test_setup_prerequisites.ps1 -PackageOnly -HardwareProfile Generic
   ```

   檢查會核對主程式檔案與語法，不安裝軟體、不變更 Windows 設定，也不代表已通過實機驗收；它不取代上一步數位簽章核對。出現缺檔或錯誤時先依訊息修正，不繼續。未選擇驅動包不要求驅動檔；`Generic` 是此離線檢查使用的設定檔，實際套用時仍自動辨識機型，不能用它強制套用特定硬體設定。
7. 檢查成功後，將**整個**工具包根資料夾複製到可寫入的 USB；可保留名稱 `windows_setup`。確認 USB 副本內有兩個入口、`core`、`modules` 及剛補入的 EXE，不只複製 `.cmd`。也可直接在 USB 完成以上準備與檢查；不依賴固定磁碟代號或使用者名稱。
8. 在目標電腦插上 USB：仍在地區／Wi-Fi 畫面時，依快速開始 A 以 Shift+F10 呼叫 Init；已登入正式帳號時依快速開始 B。OOBE 流程需要完整自有設定包；SSH 元件、Windows Update 與未快取下載需要網路。

若要一併檢查已準備的 NUC 獨立包，將上述檢查參數改為 `-PackageOnly -HardwareProfile NUC8 -DriverPackagePath "實際獨立包目錄"`；這只驗證檔案，不安裝驅動。完整來源包準備不代表主程式自帶各硬體驅動，詳見下一節。以上採用官方下載與既有套件檢查，無需額外開發環境。

### 準備獨立驅動包

各版本不一定附帶驅動包；包括 NUC 使用者都可在 `windows.cmd` 的選包提示輸入 N 略過（型號沒有完全對上時 Enter 也是略過）。若所用版本的 **Release → Assets** 提供適合本機的可選 **`windows_driver_nuc8_<version>.zip`**（version 包含 v），可下載與主程式相同版本的包。將它解壓到 **`USB 根目錄\windows_driver_packages\nuc8`**，該資料夾內應直接看得到 `install.cmd`、`core`、`modules`、`drivers`、`package.json`、`manifest.json`、`license` 與十二個 ZIP；不要多包一層 ZIP 檔名資料夾。若要安裝此包，執行 `windows.cmd` 時依機型提示選擇這個資料夾。主程式仍依上節由 Source code ZIP 與官方 Autologon 準備，兩個包放在同一 USB 的相鄰資料夾。

維護者重新建包與核對方式見 [建立獨立驅動包](doc/maintainer_guide.md#建立獨立驅動包)。

`package_hashes.json` 是本機主程式交付快照，不追蹤於 Git，也不把外部驅動納入主程式。獨立驅動依自身 manifest 核對；Git clone 缺少交付快照不代表程式損壞。
### 不納入 Git 的內容

- 驅動 ZIP、Autologon EXE、安裝封存檔與其他大型二進位。
- 各機 `reports`、進度、結果、快取、備份與執行日誌。
- `.ssh`、私鑰、known_hosts、密碼、Token、Init answer file、owner/runtime/state 等實機資料。
- 本機套件雜湊快照與暫存測試副本。

忽略規則不會刪除本機完整包的必要檔案。不要為了讓 Git 工作樹乾淨而刪除驅動或使用者自訂設定。

### 公開來源與授權注意事項

公開版 `modules\ssh/custom_hosts_sync/sites.json` 使用空白 Sites，不帶公司、SSID 或實際網段；個人規則只在各機的使用者設定目錄維護。目前公開來源不預設帶入個人網路規則。

發布前仍須掃描來源與提交歷史，確認沒有密碼、私鑰、個人網路規則或實機報告。Git 作者資訊應使用適合公開的身分。

- 發布前核對目前 remote 指向的 windows_setup 儲存庫。
- 自有程式與文件採用 [Apache License 2.0](license)；第三方內容維持各自原有授權。
- 若要提供完整二進位下載包，先確認各第三方再散布權限；不能直接把忽略中的驅動和 EXE 全數上傳。

第三方來源與各自授權見 [第三方來源與授權](doc/third_party.md)。儲存庫可設定 remote 並依維護者授權發布；請以目前 Git remote 與 GitHub 狀態為準。

## 專案架構與依賴方向

維護工具與交付執行樹的責任、依賴及既有識別見 [專案架構與依賴方向](doc/maintainer_guide.md#專案架構與依賴方向)。

## Windows CI

測試工作流程與品質門檻見 [Windows CI](doc/ci_guide.md#windows-ci)。

### 平行測試與完整證據聚合

見 [平行測試與完整證據聚合](doc/ci_guide.md#平行測試與完整證據聚合)。

### 自動報表與徽章

見 [自動報表與徽章](doc/ci_guide.md#自動報表與徽章)。

### 測試分層與本機入口

見 [測試分層與本機入口](doc/ci_guide.md#測試分層與本機入口)。

### 開發用 Windows Docker 環境

維護者容器環境見 [Windows Docker](doc/ci_guide.md#開發用-windows-docker-環境)；一般使用不需 Docker。

## 維護者版本發布

版本準備與發布見 [維護者版本發布](doc/maintainer_guide.md#維護者版本發布)。

### 準備版本與 Pull Request

見 [準備版本與 Pull Request](doc/maintainer_guide.md#準備版本與-pull-request)。

### 標籤與發布門檻

見 [標籤與發布門檻](doc/maintainer_guide.md#標籤與發布門檻)。

### 下載內容與保留期限

見 [下載內容與保留期限](doc/maintainer_guide.md#下載內容與保留期限)。

### 維護者準備獨立驅動資產

見 [維護者準備獨立驅動資產](doc/maintainer_guide.md#維護者準備獨立驅動資產)。

### 本機檢查發布內容

見 [本機檢查發布內容](doc/maintainer_guide.md#本機檢查發布內容)。

### 檔名與舊版相容性

見 [檔名與舊版相容性](doc/maintainer_guide.md#檔名與舊版相容性)。

### 自動需求驗收與獨立審查

見 [自動需求驗收與獨立審查](doc/maintainer_guide.md#自動需求驗收與獨立審查)及 [維護規範](agents.md)。

### 自有測試暫存的預覽與清理

見 [自有測試暫存的預覽與清理](doc/maintainer_guide.md#自有測試暫存的預覽與清理)。

### 提交訊息輔助檢查

見 [提交訊息輔助檢查](doc/maintainer_guide.md#提交訊息輔助檢查)。
