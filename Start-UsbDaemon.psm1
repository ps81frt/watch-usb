function Start-UsbDaemon {
    param(
        [string[]]$AutoAttach = @(),
        [string[]]$AutoDetach = @(),
        [string]  $LogFile    = "$env:TEMP\usb-dmesg.log"
    )

    $counters  = @{ branche=0; debranche=0; attach=0; detach=0; erreur=0; change=0 }
    $startedAt = Get-Date
    $statTimer = [System.Diagnostics.Stopwatch]::StartNew()

    $colorMap = @{
        INFO   = "Gray"
        DEV    = "Green"
        UNPLUG = "Magenta"
        WARN   = "Yellow"
        ACT    = "Cyan"
        ERR    = "Red"
        STAT   = "DarkCyan"
        DBG    = "DarkGray"
    }

    function Log($level, $msg) {
        $time = Get-Date -Format "HH:mm:ss.fff"
        $line = "[$time] [$level] $msg"
        Add-Content $LogFile $line
        $col = if ($colorMap.ContainsKey($level)) { $colorMap[$level] } else { "White" }
        Write-Host $line -ForegroundColor $col
    }

    function Format-Uptime {
        $d = (Get-Date) - $startedAt
        "{0:D2}h{1:D2}m{2:D2}s" -f [int]$d.TotalHours, $d.Minutes, $d.Seconds
    }

    function Write-Stats {
        Log "STAT" ("uptime=$(Format-Uptime) | branché={0} débranché={1} attach={2} detach={3} change={4} erreur={5}" -f `
            $counters.branche, $counters.debranche, $counters.attach, $counters.detach, $counters.change, $counters.erreur)
    }

    function Resolve-VidClass($vidpid) {
        $vid = $vidpid.Split(":")[0].ToLower()
        $table = @{
            "046d" = "HID/Logitech"
            "045e" = "HID/Microsoft"
            "04d9" = "HID/Holtek"
            "05ac" = "HID/Apple"
            "0bda" = "Stockage/Realtek"
            "0781" = "Stockage/SanDisk"
            "0951" = "Stockage/Kingston"
            "04e8" = "Mobile/Samsung"
            "18d1" = "Mobile/Google"
            "2109" = "Hub/VIA"
            "1a40" = "Hub/Terminus"
            "1d6b" = "Hub/Linux"
            "8087" = "Hub/Intel"
        }
        if ($table.ContainsKey($vid)) { return $table[$vid] }
        return "Inconnu/$vid"
    }

    function Resolve-VidPid($deviceId) {
        if ($deviceId -match "VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})") {
            return ("$($matches[1]):$($matches[2])").ToLower()
        }
        return $null
    }

    function Resolve-CimStatus($status) {
        switch ($status) {
            "OK"       { return "OPÉRATIONNEL" }
            "Degraded" { return "DÉGRADÉ"      }
            "Error"    { return "ERREUR"        }
            "Unknown"  { return "INCONNU"       }
            default    { return $status.ToUpper() }
        }
    }

    function Resolve-BusId($vidpid) {
        $lines = usbipd list 2>$null | Select-Object -Skip 2
        foreach ($l in $lines) {
            if ($l -match "^\s*([0-9-]+)\s+$([regex]::Escape($vidpid))\s+") {
                return $matches[1]
            }
        }
        return $null
    }

    function Invoke-AutoAction($vidpid, $nom) {
        if ($vidpid -notin $AutoAttach -and $vidpid -notin $AutoDetach) { return }

        $busid = Resolve-BusId $vidpid
        if (-not $busid) {
            Log "WARN" "BUSID INTROUVABLE → vid=$vidpid nom=`"$nom`" — action annulée"
            return
        }

        if ($vidpid -in $AutoAttach) {
            Log "ACT" "ATTACHEMENT AUTO → bus=$busid vid=$vidpid nom=`"$nom`""
            try {
                usbipd attach --busid $busid *> $null
                $counters.attach++
                Log "ACT" "ATTACHÉ OK → bus=$busid"
            } catch {
                $counters.erreur++
                Log "ERR" "ECHEC ATTACHEMENT → bus=$busid erreur=$($_.Exception.Message)"
            }
        }
        if ($vidpid -in $AutoDetach) {
            Log "ACT" "DÉTACHEMENT AUTO → bus=$busid vid=$vidpid nom=`"$nom`""
            try {
                usbipd detach --busid $busid *> $null
                $counters.detach++
                Log "ACT" "DÉTACHÉ OK → bus=$busid"
            } catch {
                $counters.erreur++
                Log "ERR" "ECHEC DÉTACHEMENT → bus=$busid erreur=$($_.Exception.Message)"
            }
        }
    }

    $queryBranchement   = "SELECT * FROM __InstanceCreationEvent WITHIN 1 WHERE TargetInstance ISA 'Win32_PnPEntity' AND TargetInstance.PNPClass = 'USB'"
    $queryDebranchement = "SELECT * FROM __InstanceDeletionEvent WITHIN 1 WHERE TargetInstance ISA 'Win32_PnPEntity' AND TargetInstance.PNPClass = 'USB'"

    Log "INFO" "DAEMON USB DÉMARRÉ | mode=évènement-CIM"
    Log "INFO" "LOG → $LogFile"
    Log "INFO" "auto-attach=[$($AutoAttach -join ',')] auto-detach=[$($AutoDetach -join ',')]"

    try {
        Register-CimIndicationEvent -Query $queryBranchement   -SourceIdentifier "USB.Branchement"
        Register-CimIndicationEvent -Query $queryDebranchement -SourceIdentifier "USB.Debranchement"
    } catch {
        $counters.erreur++
        Log "ERR" "Echec enregistrement CIM → $($_.Exception.Message)"
        Log "WARN" "Droits administrateur requis"
        return
    }

    Log "INFO" "Listeners CIM actifs — en attente d'évènements"

    $snapshot = @{}

    try {
        while ($true) {
            $evt = Wait-Event -Timeout 2

            if ($null -eq $evt) {
                if ($statTimer.Elapsed.TotalSeconds -ge 60) {
                    Write-Stats
                    $statTimer.Restart()
                }
                continue
            }

            $instance = $evt.SourceEventArgs.NewEvent.TargetInstance
            $nom      = $instance.Name ?? $instance.Description ?? "Inconnu"
            $deviceId = $instance.DeviceID ?? ""
            $vidpid   = Resolve-VidPid $deviceId
            $classe   = if ($vidpid) { Resolve-VidClass $vidpid } else { "Inconnu" }
            $status   = if ($instance.Status) { Resolve-CimStatus $instance.Status } else { $null }

            switch ($evt.SourceIdentifier) {
                "USB.Branchement" {
                    $detail = "nom=`"$nom`""
                    if ($vidpid) { $detail += " vid=$vidpid classe=$classe" }
                    if ($status) { $detail += " état=$status" }
                    $detail += " deviceId=$deviceId"

                    if ($snapshot.ContainsKey($deviceId) -and $snapshot[$deviceId] -ne $status) {
                        $counters.change++
                        Log "WARN" "CHANGEMENT → $($snapshot[$deviceId])→$status $detail"
                    } else {
                        $counters.branche++
                        Log "DEV" "BRANCHÉ → $detail"
                    }

                    $snapshot[$deviceId] = $status
                    if ($vidpid) { Invoke-AutoAction $vidpid $nom }
                }
                "USB.Debranchement" {
                    $counters.debranche++
                    $detail = "nom=`"$nom`""
                    if ($vidpid) { $detail += " vid=$vidpid classe=$classe" }
                    if ($status) { $detail += " état=$status" }
                    Log "UNPLUG" "DÉBRANCHÉ → $detail"
                    $snapshot.Remove($deviceId)
                }
            }

            Remove-Event -EventIdentifier $evt.EventIdentifier

            if ($statTimer.Elapsed.TotalSeconds -ge 60) {
                Write-Stats
                $statTimer.Restart()
            }
        }
    }
    finally {
        Unregister-Event -SourceIdentifier "USB.Branchement"   -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier "USB.Debranchement" -ErrorAction SilentlyContinue
        Write-Stats
        Log "INFO" "DAEMON USB ARRÊTÉ | uptime=$(Format-Uptime)"
    }
}
