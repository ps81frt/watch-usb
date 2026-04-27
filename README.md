# Installation execution.

```powershell
& {
winget install --id dorssel.usbipd-win -e | Out-Null

[Console]::OutputEncoding=[System.Text.Encoding]::UTF8
$OutputEncoding=[System.Text.Encoding]::UTF8

$moduleRoot="$HOME\Documents\PowerShell\Modules\watch-usb"
New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null

Invoke-WebRequest "https://raw.githubusercontent.com/ps81frt/watch-usb/main/watch-usb.psm1" -OutFile "$moduleRoot\watch-usb.psm1"

$envPath=[Environment]::GetEnvironmentVariable("PSModulePath","User")
if($envPath -notlike "*watch-usb*"){
[Environment]::SetEnvironmentVariable("PSModulePath",$envPath+";$HOME\Documents\PowerShell\Modules","User")
}

if(!(Test-Path $PROFILE)){
New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$c=Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if($c -notmatch "watch-usb"){
Add-Content $PROFILE "Import-Module watch-usb"
Add-Content $PROFILE "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8"
Add-Content $PROFILE "`$OutputEncoding=[System.Text.Encoding]::UTF8"
}

Import-Module watch-usb -Force

watch-usbipd
}
```
