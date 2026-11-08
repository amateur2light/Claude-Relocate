# claude-relocate

`Move-ClaudeData.ps1` is a PowerShell script to move the Claude desktop app data (`%APPDATA%\Claude`, often 10+ GB) from `C:` to any drive or folder. It copies the data, leaves a junction at the original path so Claude keeps working, clears caches, and keeps a backup until you confirm.

## Requirements

- Windows 10 / 11, PowerShell 5.1+
- Claude desktop app opened at least once
- Destination on a local drive

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\Move-ClaudeData.ps1                      # prompts for destination
.\Move-ClaudeData.ps1 -Destination "E:\Claude"                                       # move
.\Move-ClaudeData.ps1 -Destination "E:\Claude" -KeepBackup                           # keep Claude.bak
.\Move-ClaudeData.ps1 -Rollback -Destination "E:\Claude"                             # undo
.\Move-ClaudeData.ps1 --help                                                         # help
```

Data is moved to `<Destination>\AppData-Claude`.

## Verify

```powershell
Get-Item "$env:APPDATA\Claude" | Select-Object LinkType, Target
```

Should show `Junction` pointing to your destination.

## Notes

- Updates and new chats keep writing to the new location.
- Resetting or reinstalling Claude may remove the junction. Re-run the script if so.
- Keep the destination drive connected, or Claude won't load.
- Blank screen after moving: quit Claude, delete `Cache`, `Code Cache` and `GPUCache` in the destination folder, or use `-Rollback`.

## License

MIT