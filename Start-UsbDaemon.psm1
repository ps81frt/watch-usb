function Start-UsbDaemon {

    $state = @{}
    $logFile = "$env:TEMP\usb-dmesg.log"

    function Log($level, $msg) {

        $time = Get-Date -Format "HH:mm:ss.fff"
        $line = "[$time] [$level] $msg"

        Add-Content $logFile $line

        switch ($level) {
            "INFO"  { Write-Host $line -ForegroundColor Gray }
            "DEV"   { Write-Host $line -ForegroundColor Green }
            "WARN"  { Write-Host $line -ForegroundColor Yellow }
            "ACT"   { Write-Host $line -ForegroundColor Cyan }
            "ERR"   { Write-Host $line -ForegroundColor Red }
        }
    }

    function GetType($vidpid) {
        switch ($vidpid) {
            "046d:c08b" { return "Mouse (Logitech G502)" }
            "046d:082c" { return "Webcam (Logitech C615)" }
            "8087:0029" { return "Bluetooth Adapter" }
            default     { return "USB Device" }
        }
    }

    Log "INFO" "USB DAEMON STARTED"
    Log "INFO" "LOG FILE → $logFile"

    try {

        while ($true) {

            $current = @{}
            $lines = usbipd list 2>$null | Select-Object -Skip 2

            foreach ($l in $lines) {

                if ($l -match "^\s*([0-9-]+)\s+([0-9A-Fa-f:]+)\s+(.+?)\s{2,}(.+)$") {

                    $bus = $matches[1]
                    $vidpid = $matches[2]
                    $name = $matches[3].Trim()
                    $stateStr = $matches[4].Trim()

                    $type = GetType $vidpid

                    $current[$bus] = $vidpid

                    # 🟢 NEW DEVICE
                    if (-not $state.ContainsKey($bus)) {

                        Log "DEV" "PLUG → $type | $name | $vidpid | $bus"

                        if ($vidpid -eq "046d:c08b") {
                            Log "ACT" "AUTO ATTACH → $name ($bus)"
                            try {
                                usbipd attach --busid $bus *> $null
                            } catch {
                                Log "ERR" "ATTACH FAILED → $bus"
                            }
                        }
                    }

                    # 🟡 CHANGE STATE
                    elseif ($state[$bus] -ne $vidpid) {
                        Log "WARN" "STATE CHANGE → $bus | $vidpid"
                    }
                }
            }

            # 🔴 REMOVE EVENTS
            foreach ($b in $state.Keys | Where-Object { $_ -notin $current.Keys }) {
                Log "DEV" "UNPLUG → $b"
            }

            $state = $current.Clone()

            Start-Sleep -Milliseconds 500
        }
    }
            finally {
                Log "INFO" "STOPPED | log=$logFile"
    }
}
