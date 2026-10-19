Get-CimInstance Win32_Process -Filter "name='powershell.exe'" | Where-Object { $_.CommandLine -like '*UsageHud.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
