function Elevation {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        try {
            $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
            Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -Verb RunAs -WindowStyle Normal
            exit
        } catch {
            Write-Warning "Elevation impossible ou annulee. Le script s'arrête."
            exit 1
        }
    }
}

Elevation

function Start-DiskDaemon {
    param(
        [string]$LogFile      = "$env:TEMP\disk-monitor.log",
        [int]$PollingInterval = 5,
        [int]$SmartInterval   = 30
    )

    $counters  = @{ connecte=0; deconnecte=0; change=0; smart=0; erreur=0 }
    $startedAt = Get-Date
    $statTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $smartTimer = [System.Diagnostics.Stopwatch]::StartNew()

    $colorMap = @{
        INFO   = "Gray"
        DEV    = "Green"
        UNPLUG = "Magenta"
        WARN   = "Yellow"
        SMART  = "DarkYellow"
        ERR    = "Red"
        STAT   = "DarkCyan"
        BOOT   = "Cyan"
    }

    function Log {
        param(
            [string]$level,
            [string]$msg
        )
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
        Log "STAT" ("uptime=$(Format-Uptime) | connecte={0} deconnecte={1} changement={2} smart={3} erreur={4}" -f `
            $counters.connecte, $counters.deconnecte, $counters.change, $counters.smart, $counters.erreur)
    }

    function Get-MediaLabel {
        param([string]$mediaType)
        switch ($mediaType) {
            "HDD"         { return "HDD" }
            "SSD"         { return "SSD" }
            "SCM"         { return "SCM" }
            "3"           { return "HDD" }
            "4"           { return "SSD" }
            "5"           { return "SCM" }
            default {
                if ($mediaType -and $mediaType -ne "Unspecified") { return $mediaType }
                return "Inconnu"
            }
        }
    }

    function Resolve-VidPid {
        param([string]$deviceId)
        if ($deviceId -match "VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})") {
            return ("$($matches[1]):$($matches[2])").ToLower()
        }
        return $null
    }

    function Resolve-VidClass {
        param([string]$vidpid)
        if (-not $vidpid) { return $null }
        $vid = $vidpid.Split(":")[0].ToLower()
        $table = @{
            "0bda" = "Stockage/Realtek"
            "0781" = "Stockage/SanDisk"
            "0951" = "Stockage/Kingston"
            "1058" = "Stockage/WD"
            "0bc2" = "Stockage/Seagate"
            "04e8" = "Mobile/Samsung"
            "18d1" = "Mobile/Google"
            "046d" = "HID/Logitech"
            "045e" = "HID/Microsoft"
            "05ac" = "HID/Apple"
            "2109" = "Hub/VIA"
            "8087" = "Hub/Intel"
        }
        if ($table.ContainsKey($vid)) { return $table[$vid] }
        return "Inconnu/VID=$vid"
    }
        function Get-NvmeVendorInfo {
        param([string]$model, [string]$pnpDeviceId)
        
        $vendorMap = @{
            "VALUE" = @{ VendorId = "0x1E93"; VendorName = "Value Tech" }
            "SAMSUNG" = @{ VendorId = "0x144D"; VendorName = "Samsung" }
            "WDC" = @{ VendorId = "0x15B7"; VendorName = "Western Digital" }
            "KINGSTON" = @{ VendorId = "0x2646"; VendorName = "Kingston" }
            "CRUCIAL" = @{ VendorId = "0xC0A9"; VendorName = "Micron/Crucial" }
            "INTEL" = @{ VendorId = "0x8086"; VendorName = "Intel" }
            "SK HYNIX" = @{ VendorId = "0x1C5C"; VendorName = "SK Hynix" }
            "TOSHIBA" = @{ VendorId = "0x1179"; VendorName = "Toshiba/Kioxia" }
        }
        
        foreach ($key in $vendorMap.Keys) {
            if ($model -match $key) {
                return $vendorMap[$key]
            }
        }
        
        if ($pnpDeviceId -match "VEN_([0-9A-F]{4})") {
            return @{ VendorId = "0x$($matches[1])"; VendorName = "Inconnu/VEN_$($matches[1])" }
        }
        
        return @{ VendorId = $null; VendorName = $null }
    }
    function Get-UsbDiskFromPnP {
        $result = @{}
        $usbDevices = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | 
            Where-Object { 
                $_.DeviceID -match "VID_[0-9A-F]{4}&PID_[0-9A-F]{4}" -and 
                $_.PNPClass -eq "DiskDrive"
            }
        
        foreach ($device in $usbDevices) {
            $vidpid = Resolve-VidPid $device.DeviceID
            $serial = if ($device.DeviceID -match "\\([^\\]+)$") { $matches[1] }
            
            $result[$serial] = [PSCustomObject]@{
                FriendlyName = $device.Name
                VidPid = $vidpid
                DeviceId = $device.DeviceID
                Serial = $serial
            }
        }
        return $result
    }
    function Get-DiskSnapshot {
        $snap = @{}
        try {
            $physicalDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
            $usbPnPDisks = Get-UsbDiskFromPnP
            $usbDevicesBySerial = @{}
            $allPnP = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | 
                Where-Object { $_.DeviceID -like "USB\VID_*" }
            foreach ($device in $allPnP) {
                $parts = $device.DeviceID -split '\\'
                $serial = $parts[-1]
                $usbDevicesBySerial[$serial] = $device
            }
            
            $cimDisksBySerial = @{}
            $allDiskDrives = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue
            foreach ($drive in $allDiskDrives) {
                $parts = $drive.PNPDeviceID -split '\\'
                $serial = $parts[-1]
                $cimDisksBySerial[$serial] = $drive
            }
        
            
            foreach ($pd in $physicalDisks) {
                $cim = $null
                $serial = $null
                $usbparent = $null
                
                foreach ($cimSerial in $cimDisksBySerial.Keys) {
                    if ($pd.FriendlyName -like "*$cimSerial*" -or $cimSerial -like "*$($pd.FriendlyName)*") {
                        $serial = $cimSerial
                        $cim = $cimDisksBySerial[$cimSerial]
                        $usbparent = $usb.DeviceId
                        break
                    }
                }
                
                if (-not $cim) {
                    $cim = $cimDisksBySerial.Values | Where-Object { 
                        $_.Model -like "*$($pd.FriendlyName)*" -or 
                        $pd.FriendlyName -like "*$($_.Model)*" 
                    } | Select-Object -First 1
                    if ($cim) {
                        $serial = $cimDisksBySerial.GetEnumerator() | 
                            Where-Object { $_.Value -eq $cim } | 
                            Select-Object -First 1 -ExpandProperty Key
                    }
                }
                
                $pnpId = if ($cim) { $cim.PNPDeviceID } else { "" }
                $iface = if ($cim) { 
                    if ($cim.InterfaceType -eq "SCSI" -and $cim.PNPDeviceID -match "NVME") { "NVMe" }
                    elseif ($cim.InterfaceType -eq "SCSI" -and $cim.PNPDeviceID -match "SATA") { "SATA" }
                    elseif ($cim.InterfaceType -eq "USB") { "USB" }
                    else { $cim.InterfaceType }
                } else { "Inconnu" }                
                $usbDevice = if ($serial -and $usbDevicesBySerial.ContainsKey($serial)) {
                    $usbDevicesBySerial[$serial]
                } elseif ($pnpId) {
                    $usbDevicesBySerial.Values | Where-Object {
                        $pnpId -like "*$($_.DeviceID.Split('\')[-1])*"
                    } | Select-Object -First 1
                } else {
                    $null
                }
                if (-not $vidpid) {
                    foreach ($usb in $usbPnPDisks.Values) {
                        if ($usb.FriendlyName -like "*$($pd.FriendlyName)*" -or $pd.FriendlyName -like "*$($usb.FriendlyName)*") {
                            $vidpid = $usb.VidPid
                            $usbparent = $usb.DeviceId
                            break
                        }
                    }
                }
                $vidpid = if ($usbDevice) { 
                    Resolve-VidPid $usbDevice.DeviceID 
                } else { 
                    Resolve-VidPid $pnpId 
                }
                
                
                $vidclass = Resolve-VidClass $vidpid
                $vendorId = if ($vidpid) { $vidpid.Split(":")[0] } else { $null }
                $productId = if ($vidpid) { $vidpid.Split(":")[1] } else { $null }
                $nvmeInfo = if (-not $vidpid) { Get-NvmeVendorInfo $pd.FriendlyName $pnpId } else { $null }
                $nvmeParent = if (-not $vidpid -and $cim) {
                    $parentId = $cim.PNPDeviceID -replace 'SCSI\\.+\\', ''
                    $parent = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | 
                        Where-Object { $_.DeviceID -like "*$parentId*" -and $_.PNPClass -eq "SCSIAdapter" } |
                        Select-Object -First 1
                    if ($parent) { $parent.DeviceID } else { $null }
                } else { $null }

                #if ($pd.FriendlyName -match "Kingston") {
                #    Write-Host "DEBUG: pd.FriendlyName=$($pd.FriendlyName)"
                #    Write-Host "DEBUG: wmi=$cim"
                #    Write-Host "DEBUG: pnpId=$pnpId"
                #    Write-Host "DEBUG: serial=$serial"
                #    Write-Host "DEBUG: cleanSerial=$cleanSerial"
                #    Write-Host "DEBUG: usbDevice=$usbDevice"
                #}
                $snap[$pd.UniqueId] = [PSCustomObject]@{
                    UniqueId          = $pd.UniqueId
                    FriendlyName      = $pd.FriendlyName
                    MediaType         = $pd.MediaType
                    OperationalStatus = $pd.OperationalStatus
                    HealthStatus      = $pd.HealthStatus
                    Size              = $pd.Size
                    InterfaceType     = $iface
                    VidPid            = $vidpid
                    VidClass          = $vidclass
                    DeviceId          = $pnpId
                    VendorId          = $vendorId
                    ProductId         = $productId
                    UsbStorageId      = $pnpId
                    UsbParentId       = if ($usbDevice) { $usbDevice.DeviceID } else { $null }
                    UsbParentDeviceId = $usbparent          
                    NvmeVendorId   = if ($nvmeInfo) { $nvmeInfo.VendorId } else { $null }
                    NvmeVendorName = if ($nvmeInfo) { $nvmeInfo.VendorName } else { $null }
                    SerialNumber   = if ($cim) { $cim.SerialNumber } else { $null }
                    NvmeStorageId   = if ($cim -and -not $vidpid) { $cim.PNPDeviceID } else { $null }
                    NvmeParentId    = $nvmeParent
                }
            }
        } catch {}
        return $snap
    }
    function Invoke-SmartCheck {
        param([hashtable]$snap)
        foreach ($d in $snap.Values) {
            try {
                $rel = Get-PhysicalDisk -UniqueId $d.UniqueId -ErrorAction Stop | Get-StorageReliabilityCounter -ErrorAction Stop
                $media = Get-MediaLabel $d.MediaType
                $size  = if ($d.Size -gt 0) { "{0:N0} GB" -f ($d.Size / 1GB) } else { "?" }

                $issues = @()
                if ($rel.ReadErrorsTotal    -gt 0)   { $issues += "erreurs-lecture=$($rel.ReadErrorsTotal)" }
                if ($rel.WriteErrorsTotal   -gt 0)   { $issues += "erreurs-ecriture=$($rel.WriteErrorsTotal)" }
                if ($rel.Temperature        -gt 55)  { $issues += "temp=$($rel.Temperature)C" }
                if ($rel.Wear              -gt 90)   { $issues += "usure=$($rel.Wear)%" }
                if ($d.HealthStatus -ne 'Healthy')   { $issues += "sante=$($d.HealthStatus)" }

                if ($issues.Count -gt 0) {
                    $counters.smart++
                    Log "SMART" ("ALERTE --> [{0}] {1} | {2} | {3}" -f $media, $d.FriendlyName, $size, ($issues -join " | "))
                } else {
                    Log "INFO"  ("SMART OK --> [{0}] {1} | {2} | temp=$($rel.Temperature)C usure=$($rel.Wear)%" -f $media, $d.FriendlyName, $size)
                }
            } catch {
                $counters.erreur++
                Log "ERR" ("SMART ECHEC --> {0} --> {1}" -f $d.FriendlyName, $_.Exception.Message)
            }
        }
    }

    $queryConnecte     = "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_DiskDrive'"
    $queryDeconnecte   = "SELECT * FROM __InstanceDeletionEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_DiskDrive'"
    $queryModification = "SELECT * FROM __InstanceModificationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_DiskDrive'"

    Log "BOOT" "DISK MONITOR DEMARRE | log=$LogFile | polling=${PollingInterval}s | smart=${SmartInterval}s"

    try {
        Register-CimIndicationEvent -Query $queryConnecte     -SourceIdentifier "Disk.Connecte"    -ErrorAction Stop
        Register-CimIndicationEvent -Query $queryDeconnecte   -SourceIdentifier "Disk.Deconnecte"  -ErrorAction Stop
        Register-CimIndicationEvent -Query $queryModification -SourceIdentifier "Disk.Modification" -ErrorAction Stop
        Log "INFO" "Listeners CIM actifs (hot-plug natif)"
    } catch {
        $counters.erreur++
        Log "WARN" "CIM events indisponibles --> mode polling pur | $($_.Exception.Message)"
    }

    $script:snapshot = Get-DiskSnapshot

    Log "INFO" ("Disques au demarrage : {0}" -f $script:snapshot.Count)
    foreach ($d in $script:snapshot.Values) {
        $media  = Get-MediaLabel $d.MediaType
        $size   = if ($d.Size -gt 0) { "{0:N0} GB" -f ($d.Size / 1GB) } else { "?" }
        $vidStr = if ($d.VidPid) { 
            " vid=$($d.VidPid) classe=$($d.VidClass) vendor=$($d.VendorId) product=$($d.ProductId)`n       usbstor=$($d.UsbStorageId)`n       usbparent=$($d.UsbParentId)" 
        } elseif ($d.NvmeVendorId) {
            " nvmeVendor=$($d.NvmeVendorId) name=$($d.NvmeVendorName) serial=$($d.SerialNumber)`n       nvme_stor=$($d.NvmeStorageId)`n       nvme_parent=$($d.NvmeParentId)"
        } else { 
            "" 
        }        Log "INFO" ("  -> [{0}] {1} | {2} | iface={3}{4} | sante={5} | etat={6}" -f $media, $d.FriendlyName, $size, $d.InterfaceType, $vidStr, $d.HealthStatus, $d.OperationalStatus)
    }

    Log "INFO" "SMART initial :"
    Invoke-SmartCheck $script:snapshot

    $lastPoll = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while ($true) {

            $evt = Get-Event -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($evt) {
                try {
                    $instance = $evt.SourceEventArgs.NewEvent.TargetInstance
                    $nom      = if ($instance.Model)  { $instance.Model }  elseif ($instance.Caption) { $instance.Caption } else { "Inconnu" }
                    $status   = if ($instance.Status) { $instance.Status } else { "Inconnu" }
                    $size     = if ($instance.Size -gt 0) { "{0:N0} GB" -f ($instance.Size / 1GB) } else { "?" }
                    $pdInfo   = try { Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.FriendlyName -like "*$nom*" } | Select-Object -First 1 } catch { $null }
                    $media    = if ($pdInfo) { Get-MediaLabel $pdInfo.MediaType } else { "Inconnu" }

                    switch ($evt.SourceIdentifier) {
                        "Disk.Connecte" {
                            $counters.connecte++
                            $vidStr = ""
                            $iface  = "?"
                            $cimDisk = try { Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Where-Object { $_.Model -like "*$nom*" } | Select-Object -First 1 } catch { $null }
                            if ($cimDisk) {
                                $iface  = $cimDisk.InterfaceType
                                $vid    = Resolve-VidPid $cimDisk.PNPDeviceID
                                if (-not $vid -and $iface -eq "USB") {
                                    $usbMatch = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
                                                Where-Object { $_.DeviceID -match "VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4}" -and $_.Name -like "*$nom*" } |
                                                Select-Object -First 1
                                    if ($usbMatch) { $vid = Resolve-VidPid $usbMatch.DeviceID }
                                }
                                if ($vid) { $vidStr = " vid=$vid classe=$(Resolve-VidClass $vid)" }
                            }
                            Log "DEV" "CIM CONNECTE -> nom=`"$nom`" type=$media taille=$size iface=$iface$vidStr etat=$status"
                        }
                        "Disk.Deconnecte" {
                            $counters.deconnecte++
                            Log "UNPLUG" "CIM DECONNECTE -> nom=`"$nom`" type=$media taille=$size"
                        }
                        "Disk.Modification" {
                            $counters.change++
                            Log "WARN" "CIM MODIFICATION -> nom=`"$nom`" type=$media etat=$status"
                        }
                    }
                } catch {
                    $counters.erreur++
                    Log "ERR" "Traitement event CIM -> $($_.Exception.Message)"
                }
                Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue
            }
            if ($lastPoll.Elapsed.TotalSeconds -ge $PollingInterval) {
                $lastPoll.Restart()
                $current = Get-DiskSnapshot

                foreach ($uid in $script:snapshot.Keys) {
                    if (-not $current.ContainsKey($uid)) {
                        $d     = $script:snapshot[$uid]
                        $media = Get-MediaLabel $d.MediaType
                        $size  = if ($d.Size -gt 0) { "{0:N0} GB" -f ($d.Size / 1GB) } else { "?" }
                        $counters.deconnecte++
                        Log "UNPLUG" ("POLL DISPARU -> [{0}] {1} | {2}" -f $media, $d.FriendlyName, $size)
                    }
                }

                foreach ($uid in $current.Keys) {
                    if (-not $script:snapshot.ContainsKey($uid)) {
                        $d     = $current[$uid]
                        $media = Get-MediaLabel $d.MediaType
                        $size  = if ($d.Size -gt 0) { "{0:N0} GB" -f ($d.Size / 1GB) } else { "?" }
                        $counters.connecte++
                        $vidStr = if ($d.VidPid) { 
                            " vid=$($d.VidPid) classe=$($d.VidClass) vendor=$($d.VendorId) product=$($d.ProductId)`n       usbstor=$($d.UsbStorageId)`n       usbparent=$($d.UsbParentId)" 
                        } elseif ($d.NvmeVendorId) {
                        " nvmeVendor=$($d.NvmeVendorId) name=$($d.NvmeVendorName) serial=$($d.SerialNumber)`n       nvme_stor=$($d.NvmeStorageId)`n       nvme_parent=$($d.NvmeParentId)"
                        } else { 
                            "" 
                        }                        Log "DEV" ("POLL APPARU -> [{0}] {1} | {2} | iface={3}{4} | sante={5}" -f $media, $d.FriendlyName, $size, $d.InterfaceType, $vidStr, $d.HealthStatus)
                    } else {
                        $prev = $script:snapshot[$uid]
                        $d    = $current[$uid]
                        if ($prev.HealthStatus -ne $d.HealthStatus -or $prev.OperationalStatus -ne $d.OperationalStatus) {
                            $media = Get-MediaLabel $d.MediaType
                            $counters.change++
                            Log "WARN" ("POLL CHANGEMENT -> [{0}] {1} | sante: {2}-->{3} | etat: {4}-->{5}" -f `
                                $media, $d.FriendlyName, $prev.HealthStatus, $d.HealthStatus, $prev.OperationalStatus, $d.OperationalStatus)
                        }
                    }
                }

                $script:snapshot = $current
            }
            if ($smartTimer.Elapsed.TotalSeconds -ge $SmartInterval) {
                $smartTimer.Restart()
                Invoke-SmartCheck $script:snapshot
            }

            if ($statTimer.Elapsed.TotalSeconds -ge 60) {
                Write-Stats
                $statTimer.Restart()
            }

            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        Unregister-Event -SourceIdentifier "Disk.Connecte"     -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier "Disk.Deconnecte"   -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier "Disk.Modification" -ErrorAction SilentlyContinue
        Write-Stats
        Log "INFO" "DISK MONITOR ARRÊTE | uptime=$(Format-Uptime)"
    }
}

Start-DiskDaemon
