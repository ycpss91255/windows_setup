# 重跑現場 fixture：工作列登錄寫入被拒（#485）

用途：`test/powershell/unit/taskbar_rerun_write_denied_replay_tests.ps1` 以 issue #485 記錄的實機唯讀讀回狀態，重放「已完成設定的電腦重跑 `windows.cmd`，第 10 步工作列模組有一個 `New-ItemProperty` 被拒（未經授權），整輪標為失敗」的現場。

## 來源

`rerun_registry_state.json` 由 issue #485「已知事實」逐項轉錄，不含主機名、帳號、SID 或硬體型號；權限只記角色（`Administrators`、`CurrentUser`）。

- `explorer\Advanced`：`ShowTaskViewButton=0` 已存在，`TaskbarDa` 不存在；兩個角色都是 FullControl。
- `HKCU\Software\Policies\Microsoft\Windows\Explorer`：`StartLayoutFile`、`LockedStartLayout` 不存在；Administrators 為 FullControl，使用者本人只有 ReadKey。
- `HKLM\…\Windows Search` 與 `HKLM\…\Dsh`：值都已是 0。
- `ObservedDenials`：
  - `TaskbarDa`：現場日誌的第一個錯誤，原本就會被接住。
  - `HKLM\SOFTWARE\Policies\Microsoft\Dsh` 的 `AllowNewsAndInterests`：第二個、沒被接住的錯誤，已在實機確認。在 High 完整性的系統管理員 PowerShell 寫入與現值相同的 0，拋出 `UnauthorizedAccessException`；讀回的 ACL 是 Administrators FullControl，推測被系統保護擋下。乾淨安裝後第一次執行時，這個值寫入成功。
- `ConfirmedSameValueWritesOk`：同一次實機確認中，寫入相同值成功的項目。

## 限制

- 測試仍會對其他候選寫入逐一以替身拋出 `UnauthorizedAccessException` 重放，確認它們同樣能被處理。
- 替身函式不執行真正的 ACL 檢查。ACL 只作為 fixture 事實核對，拒絕由替身清單模擬。
