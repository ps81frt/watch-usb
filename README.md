# Installation execution.

```powershell
& {
Set-ExecutionPolicy Bypass -Scope CurrentUser -Force
[Console]::OutputEncoding=[System.Text.Encoding]::UTF8
$OutputEncoding=[System.Text.Encoding]::UTF8
winget install --id dorssel.usbipd-win -e
$env:Path =
    [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
    [System.Environment]::GetEnvironmentVariable("Path","User")
$moduleRoot="$HOME\Documents\PowerShell\Modules\Start-UsbDaemon"
New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
Remove-Module Start-UsbDaemon -Force -ErrorAction SilentlyContinue
Remove-Item "$moduleRoot\Start-UsbDaemon.psm1" -Force -ErrorAction SilentlyContinue
Invoke-WebRequest "https://raw.githubusercontent.com/ps81frt/Start-UsbDaemon/main/Start-UsbDaemon.psm1" -OutFile "$moduleRoot\Start-UsbDaemon.psm1"
Invoke-WebRequest "https://raw.githubusercontent.com/ps81frt/Start-UsbDaemon/main/Start-UsbDaemon.psd1" -OutFile "$moduleRoot\Start-UsbDaemon.psd1"
Unblock-File "$moduleRoot\Start-UsbDaemon.psm1"
Unblock-File "$moduleRoot\Start-UsbDaemon.psd1"
$psPath=[Environment]::GetEnvironmentVariable("PSModulePath","User")
if($psPath -notlike "*$HOME\Documents\PowerShell\Modules*"){
    [Environment]::SetEnvironmentVariable("PSModulePath",$psPath+";$HOME\Documents\PowerShell\Modules","User")
}
if(!(Test-Path $PROFILE)){
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}
$profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if($profileContent -notmatch "OutputEncoding"){
    Add-Content $PROFILE "`n[Console]::OutputEncoding=[System.Text.Encoding]::UTF8"
    Add-Content $PROFILE "`n`$OutputEncoding=[System.Text.Encoding]::UTF8"
}
Import-Module Start-UsbDaemon -Force
Start-UsbDaemon
}
```
-
![Exemple](https://file.garden/aeC5hp5FCBFcUzI_/usbipd.gif)


