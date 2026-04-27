# Installation execution.

```powershell
& {
Set-ExecutionPolicy Bypass -Scope CurrentUser -Force

[Console]::OutputEncoding=[System.Text.Encoding]::UTF8
$OutputEncoding=[System.Text.Encoding]::UTF8

winget install --id dorssel.usbipd-win -e

$moduleRoot="$HOME\Documents\PowerShell\Modules\watch-usb"
New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null

Invoke-WebRequest "https://raw.githubusercontent.com/ps81frt/watch-usb/main/watch-usb.psm1" -OutFile "$moduleRoot\watch-usb.psm1"

Unblock-File "$moduleRoot\watch-usb.psm1"

$psPath=[Environment]::GetEnvironmentVariable("PSModulePath","User")
if($psPath -notlike "*watch-usb*"){
[Environment]::SetEnvironmentVariable("PSModulePath",$psPath+";$HOME\Documents\PowerShell\Modules","User")
}

if(!(Test-Path $PROFILE)){
New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

# 🔥 FIX IMPORTANT: avoid broken profile crashing Add-Content
$profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue

if($profileContent -notmatch "watch-usb"){
Add-Content $PROFILE "`nImport-Module watch-usb"
Add-Content $PROFILE "`n[Console]::OutputEncoding=[System.Text.Encoding]::UTF8"
Add-Content $PROFILE "`$OutputEncoding=[System.Text.Encoding]::UTF8"
}

Import-Module watch-usb -Force

watch-usbipd
}
```
