# Start-Monitor.ps1
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "Ouverture de Windows Terminal..." -ForegroundColor Cyan

# Fichiers de lancement temporaires — évite les guillemets imbriqués dans wt.exe
$tmp1 = "$env:TEMP\launch-disk.ps1"
$tmp2 = "$env:TEMP\launch-usb.ps1"

Set-Content $tmp1 "& '$scriptDir\Diskmonitor.ps1'"
Set-Content $tmp2 "Import-Module '$scriptDir\Start-UsbDaemon.psm1'; Start-UsbDaemon"

$wtArgs = "--maximized new-tab --title DiskMonitor pwsh -NoExit -File `"$tmp1`" ; split-pane --vertical --title UsbDaemon pwsh -NoExit -File `"$tmp2`""

Start-Process "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe" -ArgumentList $wtArgs

Write-Host "Terminal ouvert !" -ForegroundColor Green