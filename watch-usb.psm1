[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
function watch-usbipd {
    Write-Host "Monitoring usbipd (Ctrl+C pour arrêter)..."

    $previous = @{}

    while ($true) {
        $current = @{}

        $lines = usbipd list | Select-Object -Skip 2

        foreach ($line in $lines) {
            if ($line -match "^\s*([0-9-]+)\s+([0-9A-Fa-f:]+)\s+(.+?)\s{2,}(.+)$") {
                $busid  = $matches[1]
                $vidpid = $matches[2]
                $name   = $matches[3].Trim()
                $state  = $matches[4].Trim()

                $current[$busid] = "$vidpid|$name|$state"

                if (-not $previous.ContainsKey($busid)) {
                    Write-Host "🔌 NEW: $busid $name ($vidpid) [$state]" -ForegroundColor Green
                }
                elseif ($previous[$busid] -ne $current[$busid]) {
                    Write-Host "🔄 CHANGE: $busid $name ($vidpid) [$state]" -ForegroundColor Yellow
                }
            }
        }

        foreach ($busid in $previous.Keys) {
            if (-not $current.ContainsKey($busid)) {
                Write-Host "❌ REMOVED: $busid" -ForegroundColor Red
            }
        }

        $previous = $current
        Start-Sleep -Seconds 2
    }
}
Export-ModuleMember -Function watch-usbipd
