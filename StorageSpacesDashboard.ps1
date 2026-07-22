<#
.SYNOPSIS
    Realtime web dashboard for a standalone Windows Storage Spaces subsystem.

.DESCRIPTION
    Starts a small local HTTP server (System.Net.HttpListener) that serves a
    self-contained, auto-refreshing browser dashboard. No external dependencies.

    Metrics shown:
      * Per-physical-disk % busy, IOPS, read/write MB/s, queue length, latency
      * Storage pool + virtual disk capacity and write-back cache size
      * Storage tiers (SSD/HDD) sizing
      * Volume free space
      * Physical disk health, media type, wear %, temperature
      * Active storage jobs (repair / rebalance / tier optimization) with progress

.NOTES
    RUN ELEVATED. Get-Counter, Get-StorageReliabilityCounter (wear/temp) and
    binding HttpListener to a port all want an elevated (Administrator) PowerShell.

    Performance counter names below are English. On a non-English Windows build
    the counter paths differ; tell me your locale and I'll localize them.

.EXAMPLE
    # Elevated PowerShell:
    powershell -ExecutionPolicy Bypass -File .\StorageSpacesDashboard.ps1

.EXAMPLE
    # Expose to other machines on the LAN (needs firewall + urlacl, see notes):
    .\StorageSpacesDashboard.ps1 -BindAll -Port 8080
#>

[CmdletBinding()]
param(
    [int]    $Port        = 8080,
    [switch] $BindAll,          # bind http://+:Port/ instead of localhost (LAN access)
    [switch] $IncludeWear = $true,   # gather SSD wear/temp (slower; needs admin)
    [switch] $NoLaunch,         # do not auto-open the browser
    [int]    $SampleMs    = 100, # background perf-counter sampling cadence (ms)
    [int]    $PollMs      = 100, # browser realtime refresh cadence (ms)
    [int]    $TopologyMs  = 5000,  # capacity/health cadence — used by BOTH the storage
                                   # collector and the browser. Most of the Drives and
                                   # Capacity pages are blank until the first tick, so
                                   # this stays responsive; the collector backs itself
                                   # off automatically if a pass takes longer than this.
    [int]    $SystemMs    = 250,   # CPU, file cache, write-back cache, tier movement.
                                   # Fast: a 1 GB write cache fills/destages in well
                                   # under a second, so 1s sampling hid the cycles.
    [int]    $JobsMs      = 5000,  # storage job polling (repair/rebalance progress)
    [int]    $WearMs      = 300000,# SMART wear/temp — expensive, changes glacially
    [int]    $LayoutMs    = 300000,# tier/drive layout — effectively static
    [switch] $ExactLayout        # attempt exact per-slab placement via Get-PhysicalExtent.
                                 # OFF by default: that cmdlet returns one row PER SLAB and
                                 # on a multi-TB pool it can run effectively forever.
)

$ErrorActionPreference = 'Stop'

# Storage Spaces FILTERS pool objects by privilege: a non-elevated caller gets an
# empty list, not an access-denied error. Get-PhysicalDisk/Get-Disk/Get-Volume all
# work unelevated, so the dashboard looks fine while pools silently vanish.
# Name of the machine being monitored — shown in the header and the tab title so
# several dashboards side by side are distinguishable at a glance.
$script:HostName = $env:COMPUTERNAME
if (-not $script:HostName) { try { $script:HostName = [System.Net.Dns]::GetHostName() } catch { $script:HostName = 'unknown host' } }

$script:IsElevated = $false
try {
    $script:IsElevated = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}

# Keep cadences sane. Very small intervals raise CPU (counter reads scale with
# disk count x frequency) with diminishing visual benefit below ~50ms.
if ($SampleMs   -lt 20)   { $SampleMs   = 20 }
if ($PollMs     -lt 20)   { $PollMs     = 20 }
if ($TopologyMs -lt 1000) { $TopologyMs = 1000 }
if ($SystemMs   -lt 100)  { $SystemMs   = 100 }
if ($JobsMs     -lt 500)  { $JobsMs     = 500 }
if ($WearMs     -lt 10000){ $WearMs     = 10000 }
if ($LayoutMs   -lt 10000){ $LayoutMs   = 10000 }

# Shared, thread-safe state written by the background sampler and read by the
# HTTP handler. Decoupling the two is what lets the browser poll every 500ms
# without each request paying the cost of sampling a rate counter.
# Every collector writes here; the HTTP handlers only ever READ from it. Because
# no storage cmdlet runs on the request thread, a slow storage call can never
# freeze the dashboard — it only delays that one collector's own snapshot.
$script:Shared = [hashtable]::Synchronized(@{
    perfJson = $null    # /api/perf   body (built by perf thread)
    topoJson = $null    # /api/topology body (built by storage thread)
    physMap  = $null    # diskNumber -> {Name,MediaType,BusType,Health}, for perf labels
    jobsData = @()      # storage jobs (built by jobs thread)
    systemJson = $null  # /api/system body (CPU, file cache, SS internals)
    wear     = @{}      # uniqueId -> {wear,temp}  (built by wear thread)
    wearProgress = $null # {done,total} while the SMART sweep is in flight
    layout   = @()      # slab placement per vdisk (built by layout thread)
    stop     = $false   # cooperative shutdown signal for every collector
    # Background runspaces have no console of their own, so they queue diagnostic
    # lines here and the main HTTP loop prints them.
    log      = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
})
function Write-Diag { param($Msg) try { $script:Shared['log'].Enqueue("$Msg") } catch {} }

# ---------------------------------------------------------------------------
# Collector 1 — Perf sampler (~450ms). PhysicalDisk counters ONLY.
# ---------------------------------------------------------------------------
# Reads counters via System.Diagnostics.PerformanceCounter, whose NextValue()
# computes each cooked rate over the interval BETWEEN reads — so reading every
# ~450ms yields ~450ms-resolution throughput/IOPS. Never calls a storage cmdlet,
# so this loop is immune to storage-subsystem stalls. Enriches with the disk map
# published by the storage thread, then pre-serializes the /api/perf JSON.
$SamplerScript = {
    param($Shared, $IntervalMs)
    $ErrorActionPreference = 'SilentlyContinue'

    $defs = @(
        @{ n = '% Idle Time';               k = 'idle' }
        @{ n = 'Disk Read Bytes/sec';       k = 'readBps' }
        @{ n = 'Disk Write Bytes/sec';      k = 'writeBps' }
        @{ n = 'Disk Reads/sec';            k = 'reads' }
        @{ n = 'Disk Writes/sec';           k = 'writes' }
        @{ n = 'Current Disk Queue Length'; k = 'queue' }
        @{ n = 'Avg. Disk sec/Read';        k = 'rlat' }
        @{ n = 'Avg. Disk sec/Write';       k = 'wlat' }
    )

    $counters  = $null
    $lastBuild = [datetime]::MinValue

    $build = {
        $cat   = New-Object System.Diagnostics.PerformanceCounterCategory 'PhysicalDisk'
        $names = @($cat.GetInstanceNames() | Where-Object { $_ -ne '_Total' } | Sort-Object -Unique)
        $tbl = @{}
        foreach ($inst in $names) {
            $per = @{}
            foreach ($d in $defs) {
                try { $per[$d.k] = New-Object System.Diagnostics.PerformanceCounter('PhysicalDisk', $d.n, $inst, $true) } catch {}
            }
            # prime — first NextValue() on a rate counter always returns 0
            foreach ($c in $per.Values) { try { $null = $c.NextValue() } catch {} }
            $tbl[$inst] = $per
        }
        $tbl
    }

    while (-not $Shared['stop']) {
        try {
            # (Re)discover disks periodically to pick up added/removed drives.
            # Rebuild rarely: each rebuild re-primes every counter and costs a
            # sample. Disks appearing/disappearing is rare.
            if ($null -eq $counters -or (([datetime]::UtcNow - $lastBuild).TotalSeconds -gt 120)) {
                $counters  = & $build
                $lastBuild = [datetime]::UtcNow
                Start-Sleep -Milliseconds 250   # let primed counters accumulate a delta
            }

            $map  = $Shared['physMap']
            # A List, not "$list += ...": array append is O(n^2) and this loop runs
            # ~10x/sec across every drive in the array.
            $list = New-Object System.Collections.Generic.List[object]
            foreach ($inst in $counters.Keys) {
                $per  = $counters[$inst]
                $vals = @{}
                foreach ($d in $defs) {
                    $v = 0.0
                    if ($per.ContainsKey($d.k)) { try { $v = [double]$per[$d.k].NextValue() } catch { $v = 0.0 } }
                    $vals[$d.k] = $v
                }
                $busy = 100 - $vals['idle']
                if ($busy -lt 0)   { $busy = 0 }
                if ($busy -gt 100) { $busy = 100 }
                $num  = ($inst -split '\s+')[0]
                $meta = if ($map) { $map["$num"] } else { $null }
                $list.Add([pscustomobject]@{
                    instance       = $inst
                    diskNumber     = $num
                    name           = if ($meta) { $meta.Name }     else { "Disk $num" }
                    mediaType      = if ($meta) { $meta.MediaType } else { 'Unknown' }
                    health         = if ($meta) { $meta.Health }    else { '' }
                    kind           = if ($meta) { $meta.Kind }      else { 'unmapped' }
                    busType        = if ($meta) { "$($meta.BusType)" } else { '' }
                    isSystem       = if ($meta) { [bool]$meta.IsSystem } else { $false }
                    busy           = [math]::Round($busy, 1)
                    readBps        = [math]::Round($vals['readBps'], 0)
                    writeBps       = [math]::Round($vals['writeBps'], 0)
                    reads          = [math]::Round($vals['reads'], 0)
                    writes         = [math]::Round($vals['writes'], 0)
                    queue          = [math]::Round($vals['queue'], 2)
                    readLatencyMs  = [math]::Round($vals['rlat'] * 1000, 2)
                    writeLatencyMs = [math]::Round($vals['wlat'] * 1000, 2)
                })
            }
            $list = @($list | Sort-Object { [int]($_.diskNumber -as [int]) })

            # Totals count PHYSICAL media only. Including the virtual disks would
            # double-count every I/O (once on the space, once on its members).
            $phys = @($list | Where-Object { $_.kind -eq 'physical' })
            $virt = @($list | Where-Object { $_.kind -eq 'virtual' })
            $totR = ($phys | Measure-Object -Property readBps  -Sum).Sum
            $totW = ($phys | Measure-Object -Property writeBps -Sum).Sum
            $totI = (($phys | Measure-Object -Property reads -Sum).Sum) + (($phys | Measure-Object -Property writes -Sum).Sum)
            $vR   = ($virt | Measure-Object -Property readBps  -Sum).Sum
            $vW   = ($virt | Measure-Object -Property writeBps -Sum).Sum
            $vI   = (($virt | Measure-Object -Property reads -Sum).Sum) + (($virt | Measure-Object -Property writes -Sum).Sum)
            $jobs = $Shared['jobsData']; if (-not $jobs) { $jobs = @() }

            $resp = [pscustomobject]@{
                timestamp = (Get-Date).ToString('o')
                # Until the storage thread publishes physMap nothing can be
                # classified, so the UI shows "waiting" instead of graphing zeros.
                mapped    = [bool]($map -and $map.Count -gt 0)
                disks     = @($list)
                totals    = [pscustomobject]@{ readBps = [double]$totR; writeBps = [double]$totW; iops = [double]$totI }
                spaceTotals = [pscustomobject]@{ readBps = [double]$vR; writeBps = [double]$vW; iops = [double]$vI }
                jobs      = @($jobs)
            }
            $Shared['perfJson'] = ($resp | ConvertTo-Json -Depth 6 -Compress)
        } catch {}
        # Interruptible sleep: check the stop flag every 100ms so shutdown is
        # prompt even for the 5s storage loop.
        $left = $IntervalMs
        while ($left -gt 0 -and -not $Shared['stop']) {
            $chunk = [math]::Min(100, $left); Start-Sleep -Milliseconds $chunk; $left -= $chunk
        }
    }
}

# ---------------------------------------------------------------------------
# Collector 2 — Storage jobs (~2s). Get-StorageJob only.
# ---------------------------------------------------------------------------
$JobsScript = {
    param($Shared, $IntervalMs)
    $ErrorActionPreference = 'SilentlyContinue'
    while (-not $Shared['stop']) {
        try {
            $jobs = @()
            try {
                $jobs = Get-StorageJob -ErrorAction Stop | ForEach-Object {
                    [pscustomobject]@{
                        name           = "$($_.Name)"
                        description    = "$($_.Description)"
                        state          = "$($_.JobState)"
                        percent        = [double]($_.PercentComplete)
                        bytesProcessed = [double]($_.BytesProcessed)
                        bytesTotal     = [double]($_.BytesTotal)
                    }
                }
            } catch {}
            $Shared['jobsData'] = @($jobs)
        } catch {}
        # Interruptible sleep: check the stop flag every 100ms so shutdown is
        # prompt even for the 5s storage loop.
        $left = $IntervalMs
        while ($left -gt 0 -and -not $Shared['stop']) {
            $chunk = [math]::Min(100, $left); Start-Sleep -Milliseconds $chunk; $left -= $chunk
        }
    }
}

# ---------------------------------------------------------------------------
# Collector 3 — Storage topology (~5s) + wear/temp (slow, ~60s sub-cadence).
# ---------------------------------------------------------------------------
# Owns every Storage* cmdlet except jobs. Publishes physMap FIRST each loop so
# the perf thread gets fresh disk labels quickly, THEN does the slow work.
# Get-StorageReliabilityCounter (SMART wear/temp) is the notorious slow call —
# it runs on its own long cadence so a 60s SMART hang can't stall topology.
# ---------------------------------------------------------------------------
# Collector 6 — System + Storage Spaces internals (~1s, own thread).
# ---------------------------------------------------------------------------
# Windows exposes Storage Spaces internals as perf counter sets that the Storage
# cmdlets don't surface at all: write-back cache occupancy and hit rate, tier
# optimisation movement, and repair/regeneration state. Plus CPU (parity is
# CPU-bound) and the Windows file cache.
$SystemScript = {
    param($Shared, $IntervalMs)
    $ErrorActionPreference = 'SilentlyContinue'

    $simpleDefs = @(
        @{ c='Processor Information'; n='% Processor Time'; i='_Total'; k='cpu' }
        @{ c='Memory'; n='Cache Bytes';                          i=''; k='memCache' }
        @{ c='Memory'; n='Available MBytes';                     i=''; k='memAvailMB' }
        @{ c='Memory'; n='Standby Cache Normal Priority Bytes';  i=''; k='memStandby' }
        @{ c='Memory'; n='Modified Page List Bytes';             i=''; k='memModified' }
        @{ c='PhysicalDisk'; n='Split IO/Sec'; i='_Total';       k='splitIo' }
    )
    # The Storage Spaces sets are MULTI-INSTANCE (one instance per pool/vdisk);
    # reading them without an instance name throws, so enumerate them.
    $ssSpecs = @(
        @{ cat='Storage Spaces Write Cache'; out='writeCache'; map=[ordered]@{
            'Cache Size'='size'; 'Cache (Used) Bytes'='used'; 'Cache (Used) %'='usedPct'
            'Cache (Reclaimable) Bytes'='reclaimable'; 'Cache (Data) Bytes'='data'
            'Write Cache %'='writeHitPct'; 'Read Cache %'='readHitPct'
            'Write Bypass %'='writeBypassPct'; 'Read Bypass %'='readBypassPct'
            'Cache Destages (Current)'='destages' } }
        @{ cat='Storage Spaces Tier'; out='tier'; map=[ordered]@{
            'Tier Transfer Bytes/sec'='bps';        'Tier Transfers/sec'='ops'
            'Tier Transfer Latency'='latency';      'Tier Transfers (Current)'='inflight'
            'Tier Transfer Bytes (Average)'='avgXfer'
            'Tier Read Bytes/sec'='readBps';        'Tier Reads/sec'='readOps'
            'Tier Read Latency'='readLat';          'Tier Read Bytes (Average)'='avgRead'
            'Tier Write Bytes/sec'='writeBps';      'Tier Writes/sec'='writeOps'
            'Tier Write Latency'='writeLat';        'Tier Write Bytes (Average)'='avgWrite' } }
        @{ cat='Storage Spaces Virtual Disk'; out='vdisk'; map=[ordered]@{
            'Virtual Disk Need Regeneration Bytes'='needRegen'; 'Virtual Disk Stale Bytes'='stale'
            'Virtual Disk Missing Bytes'='missing'; 'Virtual Disk Active Bytes'='active'
            'Virtual Disk Total Bytes'='total'; 'Virtual Disk Scrub Bytes/sec'='scrubBps'
            'Virtual Disk Repair Replacement Bytes'='repairBytes' } }
    )

    $simple=@{}; $ss=@{}; $lastBuild=[datetime]::MinValue
    $build = {
        $simple.Clear(); $ss.Clear()
        foreach ($d in $simpleDefs) {
            try {
                $pc = New-Object System.Diagnostics.PerformanceCounter($d.c,$d.n,$d.i,$true)
                $null = $pc.NextValue(); $simple[$d.k] = $pc
            } catch {}
        }
        foreach ($spec in $ssSpecs) {
            $list = @()
            try {
                $cat   = New-Object System.Diagnostics.PerformanceCounterCategory($spec.cat)
                $insts = @($cat.GetInstanceNames() | Sort-Object -Unique)
                foreach ($inst in $insts) {
                    $per = [ordered]@{}
                    foreach ($cn in $spec.map.Keys) {
                        try {
                            $pc = New-Object System.Diagnostics.PerformanceCounter($spec.cat,$cn,$inst,$true)
                            $null = $pc.NextValue(); $per[$spec.map[$cn]] = $pc
                        } catch {}
                    }
                    if ($per.Count) { $list += ,([pscustomobject]@{ inst=$inst; ctrs=$per }) }
                }
            } catch {}
            $ss[$spec.out] = $list
        }
    }

    while (-not $Shared['stop']) {
        try {
            # rediscover instances periodically (a new vdisk adds one)
            if (-not $simple.Count -or (([datetime]::UtcNow - $lastBuild).TotalSeconds -gt 30)) {
                & $build; $lastBuild = [datetime]::UtcNow
            }
            $vals = [ordered]@{ timestamp = (Get-Date).ToString('o') }
            foreach ($k in @($simple.Keys)) {
                try { $vals[$k] = [math]::Round([double]$simple[$k].NextValue(),2) } catch {}
            }
            foreach ($grp in @($ss.Keys)) {
                $rows = @()
                foreach ($e in $ss[$grp]) {
                    $row = [ordered]@{ instance = "$($e.inst)" }
                    foreach ($vk in @($e.ctrs.Keys)) {
                        try { $row[$vk] = [math]::Round([double]$e.ctrs[$vk].NextValue(),2) } catch {}
                    }
                    $rows += ,([pscustomobject]$row)
                }
                $vals[$grp] = @($rows)
            }
            $Shared['systemJson'] = ($vals | ConvertTo-Json -Depth 5 -Compress)
        } catch {}
        $left = $IntervalMs
        while ($left -gt 0 -and -not $Shared['stop']) {
            $chunk = [math]::Min(100, $left); Start-Sleep -Milliseconds $chunk; $left -= $chunk
        }
    }
}

# ---------------------------------------------------------------------------
# Collector 4 — SMART wear/temp (slow, own thread).
# ---------------------------------------------------------------------------
# Get-StorageReliabilityCounter routinely blocks for many seconds per drive and
# can hang outright on a drive that won't answer. It gets its own thread so it
# can never delay the topology the rest of the dashboard depends on.
$WearScript = {
    param($Shared, $IntervalMs, $Enabled)
    $ErrorActionPreference = 'SilentlyContinue'
    while (-not $Shared['stop']) {
        if ($Enabled) {
            try {
                $wt = @{}
                $all = @(Get-PhysicalDisk -ErrorAction Stop)
                $done = 0
                foreach ($pd in $all) {
                    if ($Shared['stop']) { break }
                    try {
                        $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
                        $wt["$($pd.UniqueId)"] = [pscustomobject]@{ wear = $rc.Wear; temp = $rc.Temperature }
                    } catch {}
                    $done++
                    # Publish AFTER EVERY DRIVE. SMART reads are the slowest calls
                    # in the system; waiting for all 37 meant minutes of blank
                    # wear/temp that looked like the feature was broken.
                    # A fresh copy each time so readers never enumerate a hashtable
                    # that this thread is still writing to.
                    $Shared['wear'] = @{} + $wt
                    $Shared['wearProgress'] = [pscustomobject]@{ done = $done; total = $all.Count }
                }
            } catch {}
        }
        $left = $IntervalMs
        while ($left -gt 0 -and -not $Shared['stop']) {
            $chunk = [math]::Min(100, $left); Start-Sleep -Milliseconds $chunk; $left -= $chunk
        }
    }
}

# ---------------------------------------------------------------------------
# Collector 5 — Data layout / slab placement (very slow, own thread).
# ---------------------------------------------------------------------------
# Get-PhysicalExtent returns ONE ROW PER SLAB. On a multi-TB pool that is easily
# hundreds of thousands of rows, so we stream the pipeline and aggregate on the
# fly (never materialise the whole set) and cap the work with $MaxExtents.
$LayoutScript = {
    param($Shared, $IntervalMs, $MaxExtents, $Exact, $ExactTimeoutMs)
    $ErrorActionPreference = 'SilentlyContinue'
    $exactSupported = [bool]$Exact   # cleared permanently if the extent query misbehaves

    while (-not $Shared['stop']) {
        try {
            # One Get-Disk pass for the number lookup instead of one call per drive.
            $u2n = @{}
            try { foreach ($dk in (Get-Disk -ErrorAction Stop)) {
                    if ($dk.UniqueId) { $u2n["$($dk.UniqueId)"] = "$($dk.Number)" } } } catch {}
            $uidMap = @{}
            foreach ($pd in (Get-PhysicalDisk -ErrorAction Stop)) {
                $num = $u2n["$($pd.UniqueId)"]
                if (-not $num) { $num = "$($pd.DeviceId)" }
                $uidMap["$($pd.UniqueId)"] = [pscustomobject]@{
                    name = "$($pd.FriendlyName)"; media = "$($pd.MediaType)"; num = "$num"
                }
            }

            $lay = @()
            foreach ($vd in (Get-VirtualDisk -ErrorAction Stop)) {
                if ($Shared['stop']) { break }
                $vdName = "$($vd.FriendlyName)"

                # ---- FAST PATH: member drives + tier parameters -------------
                # Plain CIM associations. No per-slab enumeration, so this stays
                # fast no matter how large the pool is.
                $members = @()
                try {
                    $members = @($vd | Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
                        $m = $uidMap["$($_.UniqueId)"]
                        [pscustomobject]@{
                            number = if ($m) { $m.num } else { $null }
                            name = "$($_.FriendlyName)"; mediaType = "$($_.MediaType)"
                            size = [double]$_.Size
                        }
                    })
                } catch {}

                $tierInfo = @()
                try {
                    foreach ($t in (Get-StorageTier -VirtualDisk $vd -ErrorAction Stop)) {
                        $tmt = "$($t.MediaType)"
                        $tierInfo += [pscustomobject]@{
                            name = "$($t.FriendlyName)"; mediaType = $tmt; size = [double]$t.Size
                            columns = [int]$t.NumberOfColumns; copies = [int]$t.NumberOfDataCopies
                            resiliency = "$($t.ResiliencySettingName)"
                            drives = @($members | Where-Object { $_.mediaType -eq $tmt })
                        }
                    }
                } catch {}
                # Untiered space: synthesise one pseudo-tier per distinct media type.
                if (-not $tierInfo.Count) {
                    foreach ($mt in (@($members | ForEach-Object { $_.mediaType }) | Sort-Object -Unique)) {
                        $tierInfo += [pscustomobject]@{
                            name = 'data'; mediaType = "$mt"
                            size = [double](@($members | Where-Object { $_.mediaType -eq $mt } |
                                    Measure-Object -Property size -Sum).Sum)
                            columns = [int]$vd.NumberOfColumns; copies = [int]$vd.NumberOfDataCopies
                            resiliency = "$($vd.ResiliencySettingName)"
                            drives = @($members | Where-Object { $_.mediaType -eq $mt })
                        }
                    }
                }

                # ---- OPTIONAL: exact slab placement (-ExactLayout) ----------
                # Runs in a child runspace behind a hard timeout, because
                # Get-PhysicalExtent can run effectively forever on a big pool.
                $cells = @(); $isExact = $false; $partial = $false; $n = 0
                if ($exactSupported) {
                    $ps2 = $null
                    try {
                        $ps2 = [powershell]::Create()
                        $null = $ps2.AddScript({
                            param($Name,$Max)
                            Get-VirtualDisk -FriendlyName $Name | Get-PhysicalExtent |
                                Select-Object -First $Max |
                                Select-Object ColumnNumber,CopyNumber,PhysicalDiskUniqueId,Size
                        }).AddArgument($vdName).AddArgument($MaxExtents)
                        $h = $ps2.BeginInvoke()
                        if ($h.AsyncWaitHandle.WaitOne($ExactTimeoutMs)) {
                            $rows = @($ps2.EndInvoke($h))
                            $n = $rows.Count
                            if ($n -ge $MaxExtents) { $partial = $true }
                            $agg = @{}
                            foreach ($e in $rows) {
                                $uid = "$($e.PhysicalDiskUniqueId)"
                                $col = [int]$e.ColumnNumber; $cp = [int]$e.CopyNumber
                                $key = "$cp|$col|$uid"
                                if (-not $agg.ContainsKey($key)) {
                                    $m = $uidMap[$uid]
                                    $agg[$key] = [pscustomobject]@{
                                        column = $col; copy = $cp
                                        diskName   = if ($m) { $m.name }  else { '(unknown drive)' }
                                        diskNumber = if ($m) { $m.num }   else { $null }
                                        mediaType  = if ($m) { $m.media } else { 'Unknown' }
                                        bytes = [double]0; slabs = 0
                                    }
                                }
                                $agg[$key].bytes += [double]$e.Size
                                $agg[$key].slabs++
                            }
                            $cells   = @($agg.Values | Sort-Object copy, column)
                            $isExact = $cells.Count -gt 0
                            try { $ps2.Dispose() } catch {}
                        } else {
                            # Timed out. Give up on exact placement for good rather
                            # than leaking a stuck runspace on every cycle. Do NOT
                            # Dispose() — that would block on the running command.
                            $exactSupported = $false
                        }
                    } catch { $exactSupported = $false; try { $ps2.Dispose() } catch {} }
                }

                $lay += [pscustomobject]@{
                    name       = $vdName
                    resiliency = "$($vd.ResiliencySettingName)"
                    columns    = [int]$vd.NumberOfColumns
                    copies     = [int]$vd.NumberOfDataCopies
                    interleave = [double]$vd.Interleave
                    exact      = $isExact
                    partial    = $partial
                    extents    = $n
                    exactTried = [bool]$Exact
                    cells      = @($cells)
                    tiers      = @($tierInfo)
                    members    = @($members)
                }
            }
            $Shared['layout'] = $lay
        } catch {}
        $left = $IntervalMs
        while ($left -gt 0 -and -not $Shared['stop']) {
            $chunk = [math]::Min(100, $left); Start-Sleep -Milliseconds $chunk; $left -= $chunk
        }
    }
}

$StorageScript = {
    param($Shared, $IntervalMs)
    $ErrorActionPreference = 'SilentlyContinue'
    # measured inside the worker, not the parent — that's the context that matters
    $elev = $false
    try {
        $elev = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {}
    $lastPoolState = $null
    $lastPassMs = 0
    $backoffLogged = $false

    while (-not $Shared['stop']) {
        try {
            $swPass = [System.Diagnostics.Stopwatch]::StartNew()
            # --- physical disks + publish disk map ASAP (perf thread needs it) ---
            $map      = @{}
            $numByUid = @{}
            $physList = @()
            $pds      = @()
            try { $pds = @(Get-PhysicalDisk -ErrorAction Stop) } catch {}
            # Base layer: Get-Disk enumerates EVERY disk the perf counters can
            # report — pool media, RAID logical drives, and Storage Spaces virtual
            # disks (BusType 'Spaces'). Without this, anything not returned by
            # Get-PhysicalDisk showed up as a nameless "Disk N / Unknown".
            # ONE enumeration gives both the base map and a UniqueId -> disk-number
            # lookup. Previously this was followed by a Get-Disk -UniqueId PER DRIVE,
            # so on a 37-drive array physMap took tens of seconds to publish — and
            # until it did, every perf row was kind='unmapped', which made
            # isPoolMedia() reject them and pinned all throughput/tier stats to zero.
            $uidToNum = @{}
            try {
                foreach ($dk in (Get-Disk -ErrorAction Stop)) {
                    $bt   = "$($dk.BusType)"
                    $sys  = [bool]($dk.IsSystem -or $dk.IsBoot)
                    $kind = if ($bt -eq 'Spaces') { 'virtual' } elseif ($sys) { 'system' } else { 'other' }
                    $map["$($dk.Number)"] = [pscustomobject]@{
                        Name = "$($dk.FriendlyName)"; MediaType = 'Unspecified'
                        BusType = $bt; Health = "$($dk.HealthStatus)"
                        Kind = $kind; IsSystem = $sys
                    }
                    if ($dk.UniqueId) { $uidToNum["$($dk.UniqueId)"] = "$($dk.Number)" }
                }
            } catch {}

            # Overlay real media details for anything Get-PhysicalDisk knows about.
            # Pool members are often absent from Get-Disk (claimed by Storage
            # Spaces), so fall back to DeviceId, which is the disk number for them.
            foreach ($pd in $pds) {
                $num = $uidToNum["$($pd.UniqueId)"]
                if (-not $num) { $num = "$($pd.DeviceId)" }
                $numByUid["$($pd.UniqueId)"] = "$num"   # so status rows join to perf rows by disk #
                $prev = $map["$num"]
                $sys  = if ($prev) { [bool]$prev.IsSystem } else { $false }
                $map["$num"] = [pscustomobject]@{
                    Name = $pd.FriendlyName; MediaType = "$($pd.MediaType)"
                    BusType = "$($pd.BusType)"; Health = "$($pd.HealthStatus)"
                    Kind = 'physical'; IsSystem = $sys
                }
            }
            # Publish NOW: media type + kind are resolved, which is everything the
            # perf thread needs for throughput/tier stats. The vdisk naming below
            # is cosmetic and republishes a moment later.
            $Shared['physMap'] = $map
            $mapMs = $swPass.ElapsedMilliseconds
            # Storage Spaces VIRTUAL disks also appear as PhysicalDisk perf-counter
            # instances (they're disk devices to the OS) but are NOT returned by
            # Get-PhysicalDisk. Unmapped they showed up as a bogus "Unknown tier"
            # carrying all the volume I/O — double-counting the member drives.
            $vdNumByName = @{}
            try {
                foreach ($vd in (Get-VirtualDisk -ErrorAction Stop)) {
                    $vnum = $null
                    try { $vnum = ($vd | Get-Disk -ErrorAction Stop).Number } catch {}
                    if ($null -ne $vnum) {
                        $vdNumByName["$($vd.FriendlyName)"] = "$vnum"
                        $map["$vnum"] = [pscustomobject]@{
                            Name = "$($vd.FriendlyName)"; MediaType = 'Space'
                            BusType = "$($vd.ResiliencySettingName)"
                            Health = "$($vd.HealthStatus)"; Kind = 'virtual'; IsSystem = $false
                        }
                    }
                }
            } catch {}
            $Shared['physMap'] = $map   # <-- published before the slow queries below

            # Wear/temp is produced by its own thread (SMART reads can block for
            # many seconds) — just read whatever it has published.
            $wearTable = $Shared['wear']; if (-not $wearTable) { $wearTable = @{} }
            foreach ($pd in $pds) {
                $w = $wearTable["$($pd.UniqueId)"]
                $pnum = $numByUid["$($pd.UniqueId)"]
                $pmeta = $map["$pnum"]
                $physList += [pscustomobject]@{
                    number    = $pnum
                    isSystem  = if ($pmeta) { [bool]$pmeta.IsSystem } else { $false }
                    canPool   = [bool]$pd.CanPool
                    deviceId  = "$($pd.DeviceId)"
                    name      = "$($pd.FriendlyName)"
                    mediaType = "$($pd.MediaType)"
                    busType   = "$($pd.BusType)"
                    usage     = "$($pd.Usage)"
                    size      = [double]$pd.Size
                    health    = "$($pd.HealthStatus)"
                    opStatus  = "$($pd.OperationalStatus)"
                    wear      = if ($w) { [double]$w.wear } else { $null }
                    tempC     = if ($w) { [double]$w.temp } else { $null }
                }
            }

            # --- pools ---
            $pools = @(); $poolRaw = 0; $poolErr = ''; $poolVia = ''
            try {
                # Three escalating attempts, and the failure reason is RECORDED
                # rather than swallowed — a silent catch here is exactly why an
                # empty pool list was previously indistinguishable from a broken
                # query. Last resort talks to CIM directly, bypassing the
                # Storage module's cmdlet wrapper entirely.
                $poolObjs = @()
                try {
                    $poolObjs = @(Get-StoragePool -IsPrimordial $false -ErrorAction Stop)
                    if ($poolObjs.Count) { $poolVia = 'filtered' }
                } catch { $poolErr = "filtered: $($_.Exception.Message)" }
                if (-not $poolObjs.Count) {
                    try {
                        $poolObjs = @(Get-StoragePool -ErrorAction Stop | Where-Object { -not $_.IsPrimordial })
                        if ($poolObjs.Count) { $poolVia = 'unfiltered' }
                    } catch { $poolErr += " | all: $($_.Exception.Message)" }
                }
                if (-not $poolObjs.Count) {
                    try {
                        $poolObjs = @(Get-CimInstance -Namespace root/Microsoft/Windows/Storage `
                                        -ClassName MSFT_StoragePool -ErrorAction Stop |
                                      Where-Object { -not $_.IsPrimordial })
                        if ($poolObjs.Count) { $poolVia = 'cim' }
                    } catch { $poolErr += " | cim: $($_.Exception.Message)" }
                }
                if (-not $poolObjs.Count -and -not $poolErr) { $poolErr = 'all three queries returned 0 pools without error' }
                $poolRaw = @($poolObjs).Count      # found by the queries
                $pools = $poolObjs | ForEach-Object {
                    $pool = $_
                    $size = [double]$pool.Size; $alloc = [double]$pool.AllocatedSize
                    # Raw CIM returns numeric enums where the cmdlets return text.
                    $hs = "$($pool.HealthStatus)"
                    if ($hs -match '^\d+$') {
                        $hs = switch ([int]$hs) { 0 {'Healthy'} 1 {'Warning'} 2 {'Unhealthy'} default {'Unknown'} }
                    }
                    # membership drives the click-to-filter feature
                    $pdNums = @()
                    try { $pdNums = @($pool | Get-PhysicalDisk -ErrorAction Stop | ForEach-Object { $numByUid["$($_.UniqueId)"] } | Where-Object { $_ }) } catch {}
                    # NOT [math]::Max(0, ...): the literal 0 binds the Int32 overload
                    # and a multi-TB byte count then overflows Int32, throwing and
                    # killing the whole pool list.
                    $freeB = $size - $alloc
                    if ($freeB -lt 0) { $freeB = [double]0 }
                    [pscustomobject]@{
                        name = "$($pool.FriendlyName)"; health = $hs; opStatus = "$($pool.OperationalStatus)"
                        size = $size; allocated = $alloc; free = $freeB
                        pctUsed = if ($size -gt 0) { [math]::Round($alloc/$size*100,1) } else { 0 }
                        diskNumbers = @($pdNums)
                    }
                }
                $pools = @($pools)
            } catch { $poolErr += " | map: $($_.Exception.Message)" }

            # Report pool state to the console once, and again only when it changes.
            $poolState = "$poolRaw/$(@($pools).Count)/$poolErr"
            if ($poolState -ne $lastPoolState) {
                $lastPoolState = $poolState
                if (@($pools).Count) {
                    $Shared['log'].Enqueue("pools: $(@($pools).Count) found via '$poolVia' (elevated=$elev)")
                } else {
                    $Shared['log'].Enqueue("pools: NONE. queries returned=$poolRaw, survived mapping=0, elevated=$elev")
                    if ($poolErr) { $Shared['log'].Enqueue("pools: $poolErr") }
                }
            }

            # --- primordial pool: every drive Storage Spaces can see. Not a real
            # pool, but the only source for "how much media is unclaimed". ---
            $primordial = $null
            try {
                $pp = @(Get-StoragePool -ErrorAction Stop | Where-Object { $_.IsPrimordial })
                if (-not $pp.Count) {
                    $pp = @(Get-CimInstance -Namespace root/Microsoft/Windows/Storage `
                              -ClassName MSFT_StoragePool -ErrorAction Stop |
                            Where-Object { $_.IsPrimordial })
                }
                if ($pp.Count) {
                    $p0 = $pp[0]
                    $psz = [double]$p0.Size; $pal = [double]$p0.AllocatedSize
                    $pun = $psz - $pal            # same Int32 trap as above: no [math]::Max
                    if ($pun -lt 0) { $pun = [double]0 }
                    $primordial = [pscustomobject]@{
                        name = "$($p0.FriendlyName)"; size = $psz
                        allocated = $pal; unclaimed = $pun
                    }
                }
            } catch {}

            # --- virtual disks (+ per-vdisk tiers for the composition viz) ---
            $vdisks = @()
            try {
                $vdisks = Get-VirtualDisk -ErrorAction Stop | ForEach-Object {
                    $vd = $_
                    # Members are fetched FIRST so each tier can report how many
                    # drives of its media type actually back it.
                    $vdMembers = @()
                    try { $vdMembers = @($vd | Get-PhysicalDisk -ErrorAction Stop) } catch {}
                    $vdNums = @($vdMembers | ForEach-Object { $numByUid["$($_.UniqueId)"] } | Where-Object { $_ })

                    $vdTiers = @()
                    try {
                        $vdTiers = @(Get-StorageTier -VirtualDisk $vd -ErrorAction Stop | ForEach-Object {
                            $tmt = "$($_.MediaType)"
                            $tDrives = @($vdMembers | Where-Object { "$($_.MediaType)" -eq $tmt })
                            [pscustomobject]@{
                                name = "$($_.FriendlyName)"; mediaType = $tmt; size = [double]$_.Size
                                resiliency = "$($_.ResiliencySettingName)"; columns = [int]($_.NumberOfColumns)
                                copies = [int]($_.NumberOfDataCopies); redundancy = [int]($_.PhysicalDiskRedundancy)
                                driveCount = $tDrives.Count
                                # total capacity of the drives backing this tier —
                                # NOT the raw space this tier consumes
                                driveCapacity = [double](@($tDrives | Measure-Object -Property Size -Sum).Sum)
                                footprint = [double]$_.FootprintOnPool
                            }
                        } | Sort-Object { switch -Regex ($_.mediaType) { 'SSD' {0} 'SCM' {-1} 'HDD' {2} default {1} } })
                    } catch {}
                    [pscustomobject]@{
                        name = "$($vd.FriendlyName)"; health = "$($vd.HealthStatus)"; opStatus = "$($vd.OperationalStatus)"
                        size = [double]$vd.Size; footprint = [double]$vd.FootprintOnPool; allocated = [double]$vd.AllocatedSize
                        writeCacheSize = [double]$vd.WriteCacheSize; resiliency = "$($vd.ResiliencySettingName)"
                        provisioning = "$($vd.ProvisioningType)"; tiered = ($vdTiers.Count -gt 1); tiers = @($vdTiers)
                        number = $vdNumByName["$($vd.FriendlyName)"]
                        diskNumbers = @($vdNums)
                        columns = [int]$vd.NumberOfColumns; copies = [int]$vd.NumberOfDataCopies
                        redundancy = [int]$vd.PhysicalDiskRedundancy; interleave = [double]$vd.Interleave
                    }
                }
            } catch {}

            # --- tier templates ---
            $tiers = @()
            try {
                $tiers = Get-StorageTier -ErrorAction Stop | ForEach-Object {
                    [pscustomobject]@{ name = "$($_.FriendlyName)"; mediaType = "$($_.MediaType)"; size = [double]$_.Size }
                }
            } catch {}

            # --- volumes ---
            $volumes = @()
            try {
                $volumes = Get-Volume -ErrorAction Stop |
                    Where-Object { $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 } | ForEach-Object {
                        $size = [double]$_.Size; $free = [double]$_.SizeRemaining
                        [pscustomobject]@{
                            drive = if ($_.DriveLetter) { "$($_.DriveLetter):" } else { "$($_.FileSystemLabel)" }
                            label = "$($_.FileSystemLabel)"; fs = "$($_.FileSystem)"; health = "$($_.HealthStatus)"
                            size = $size; free = $free
                            pctUsed = if ($size -gt 0) { [math]::Round(($size-$free)/$size*100,1) } else { 0 }
                        }
                    }
            } catch {}

            # Layout is produced by its own thread (Get-PhysicalExtent can take a
            # very long time on a large pool) — just read what it has published.
            $layout = $Shared['layout']; if (-not $layout) { $layout = @() }

            $topo = [pscustomobject]@{
                timestamp     = (Get-Date).ToString('o')
                pools         = @($pools)
                primordial    = $primordial
                wearProgress  = $Shared['wearProgress']
                virtualDisks  = @($vdisks)
                tiers         = @($tiers)
                volumes       = @($volumes)
                physicalDisks = @($physList)
                layout        = @($layout)
                # so slow storage enumeration is visible instead of guessed at
                diag = [pscustomobject]@{
                    mapMs    = [int]$mapMs
                    passMs   = [int]$swPass.ElapsedMilliseconds
                    drives   = @($pds).Count
                    elevated = [bool]$elev     # measured in the worker runspace
                    poolRaw  = [int]$poolRaw   # pools the QUERIES returned
                    poolOut  = @($pools).Count # pools that survived MAPPING
                    poolVia  = "$poolVia"      # which query worked
                    poolErr  = "$poolErr"      # every failure, including mapping
                }
            }
            $Shared['topoJson'] = ($topo | ConvertTo-Json -Depth 6 -Compress)
            $lastPassMs = [int]$swPass.ElapsedMilliseconds
        } catch {}
        # Back off if a pass costs more than the interval, so the storage stack is
        # never driven above roughly a 50% duty cycle on a slow/large array.
        # Explicit compare, not [math]::Max — mixed int/long picks a bad overload.
        $sleepMs = $IntervalMs
        if ($lastPassMs -gt $sleepMs) {
            $sleepMs = $lastPassMs
            if (-not $backoffLogged) {
                $backoffLogged = $true
                $Shared['log'].Enqueue("topology: a scan takes ${lastPassMs}ms, longer than the ${IntervalMs}ms interval — backing off to ${sleepMs}ms between scans")
            }
        }
        # Interruptible sleep: check the stop flag every 100ms so shutdown stays prompt.
        $left = $sleepMs
        while ($left -gt 0 -and -not $Shared['stop']) {
            $chunk = [math]::Min(100, $left); Start-Sleep -Milliseconds $chunk; $left -= $chunk
        }
    }
}

# ---------------------------------------------------------------------------
# HTML (served at /)
# ---------------------------------------------------------------------------
$HtmlPage = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__HOST__ · Storage Spaces</title>
<style>
  :root{
    --bg:#0e1116; --panel:#171b22; --panel2:#1f2530; --border:#2a3140;
    --text:#e6edf3; --muted:#8b98a9; --accent:#4aa3ff; --good:#3fb950;
    --warn:#d29922; --bad:#f85149; --read:#4aa3ff; --write:#bc8cff;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--text);
    font:14px/1.4 "Segoe UI",system-ui,sans-serif}
  header{display:flex;align-items:center;gap:16px;padding:14px 20px;
    border-bottom:1px solid var(--border);background:var(--panel);position:sticky;top:0;z-index:5}
  header h1{font-size:16px;margin:0;font-weight:600}
  /* which server am I looking at — deliberately high contrast */
  .hostchip{font-size:13px;font-weight:700;letter-spacing:.4px;color:#7cc4ff;
    background:#12324a;border:1px solid #1d4d70;border-radius:6px;padding:3px 10px;
    white-space:nowrap;text-transform:uppercase}
  .dot{width:9px;height:9px;border-radius:50%;display:inline-block;margin-right:6px}
  .status{color:var(--muted);font-size:12px}
  /* shell: fixed left nav + scrolling content */
  .shell{display:flex;align-items:flex-start}
  .side{width:186px;flex:none;background:var(--panel);border-right:1px solid var(--border);
    padding:12px 9px;position:sticky;top:52px;height:calc(100vh - 52px);overflow:auto}
  .navitem{padding:9px 11px;border-radius:8px;cursor:pointer;font-size:13px;color:var(--muted);
    display:flex;align-items:center;gap:9px;margin-bottom:2px;user-select:none;white-space:nowrap}
  .navitem:hover{background:var(--panel2);color:var(--text)}
  .navitem.active{background:#17314a;color:#7cc4ff;font-weight:600}
  .navitem .nb{margin-left:auto;font-size:10px;color:var(--muted);font-weight:400}
  /* at-a-glance health, visible from every tab */
  .ndot{width:8px;height:8px;border-radius:50%;flex:none;display:none}
  .ndot.ok{display:inline-block;background:var(--good);box-shadow:0 0 0 3px rgba(63,185,80,.16)}
  .ndot.warn{display:inline-block;background:var(--warn);box-shadow:0 0 0 3px rgba(210,153,34,.20)}
  .ndot.bad{display:inline-block;background:var(--bad);box-shadow:0 0 0 3px rgba(248,81,73,.22);
    animation:pulse 1.8s ease-in-out infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.35}}
  .navitem.alert{color:#ff9b95}
  .navitem.alert.active{color:#ff9b95;background:#3a1518}
  .navitem.warnstate{color:#e8bd6d}
  .navitem.active .nb{color:#7cc4ff}
  .navsec{font-size:10px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted);
    padding:12px 11px 5px}
  .wrap{padding:18px 20px;flex:1;min-width:0}
  @media(max-width:820px){
    .shell{display:block}
    .side{width:auto;height:auto;position:static;display:flex;flex-wrap:wrap;gap:4px;border-right:none;
      border-bottom:1px solid var(--border)}
    .navsec{display:none}
    .navitem{margin-bottom:0}
  }
  .grid{display:grid;gap:16px}
  /* Wider tiles so two-part values like "127 KB / 0 B" fit on one line. */
  .kpis{grid-template-columns:repeat(auto-fit,minmax(215px,1fr));margin-bottom:16px}
  .card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:14px 16px}
  .card h2{font-size:12px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted);
    margin:0 0 10px;font-weight:600}
  /* Values change every 100ms, so nothing here may reflow: tiles are a fixed
     height, subtitles are single-line, and sparklines pin to the bottom so all
     tiles align whether or not they have one. */
  /* Fixed height, not min-height: tiles WITH a sparkline are taller than those
     without, so a minimum still left two different heights in the same row. */
  .card.kpi{height:142px;display:flex;flex-direction:column;overflow:hidden}
  /* The VALUE row must not wrap either — a two-line value squeezes the
     bottom-pinned sparkline out of the fixed-height tile. */
  .kpi>div{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .kpi .v{font-size:26px;font-weight:700}
  .kpi .u{font-size:12px;color:var(--muted);margin-left:4px}
  .kpi .sub{font-size:11px;color:var(--muted);margin-top:2px;
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-height:15px}
  .kpi .kspark{margin-top:auto;flex:none}
  table{width:100%;border-collapse:collapse;font-size:13px}
  th{text-align:left;color:var(--muted);font-weight:600;font-size:11px;
    text-transform:uppercase;letter-spacing:.4px;padding:6px 8px;border-bottom:1px solid var(--border)}
  td{padding:7px 8px;border-bottom:1px solid var(--panel2);vertical-align:middle}
  tr:last-child td{border-bottom:none}
  .bar{position:relative;height:16px;background:var(--panel2);border-radius:4px;overflow:hidden;min-width:80px}
  .bar>span{position:absolute;inset:0 auto 0 0;border-radius:4px}
  .bar em{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
    font-style:normal;font-size:11px;color:var(--text);text-shadow:0 0 3px rgba(0,0,0,.7)}
  .tag{font-size:11px;padding:1px 7px;border-radius:10px;background:var(--panel2);color:var(--muted)}
  .tag.ssd{background:#12324a;color:#7cc4ff}
  .tag.hdd{background:#2a2233;color:#c9a7ff}
  .tag.scm{background:#0f3a2e;color:#6fd7b0}
  .tag.space{background:#3a2a12;color:#f0c07a}
  /* resizable + scrollable panel bodies (drag the bottom-right corner) */
  .pbody{overflow:auto;resize:vertical;min-height:70px;position:relative}
  .pbody::-webkit-scrollbar{width:10px;height:10px}
  .pbody::-webkit-scrollbar-thumb{background:var(--border);border-radius:5px}
  .pbody::-webkit-scrollbar-thumb:hover{background:#3b4557}
  .pbody::-webkit-scrollbar-track{background:transparent}
  .pbody table thead th{position:sticky;top:0;background:var(--panel);z-index:2}
  /* click-to-filter affordances */
  [data-ft]{cursor:pointer}
  tr[data-ft]:hover>td{background:var(--panel2)}
  div[data-ft]:hover{background:var(--panel2);border-radius:6px}
  .factive{outline:1px solid var(--accent);outline-offset:-1px;border-radius:6px}
  tr.factive>td{background:rgba(74,163,255,.10)}
  #filterChip{display:flex;align-items:center;gap:7px;background:var(--panel2);
    border:1px solid var(--accent);border-radius:14px;padding:2px 6px 2px 11px;font-size:12px}
  .fclear{cursor:pointer;width:17px;height:17px;line-height:16px;text-align:center;
    border-radius:50%;background:var(--border)}
  .fclear:hover{background:var(--bad);color:#fff}
  .laygrid{display:grid;gap:4px;margin:6px 0}
  .laycell{background:var(--panel2);border-radius:4px;padding:5px 6px;font-size:10px;
    text-align:center;border-left:3px solid var(--muted);overflow:hidden}
  .laycell b{display:block;font-size:12px;margin-bottom:1px}
  .layhdr{font-size:10px;color:var(--muted);text-align:center;text-transform:uppercase;letter-spacing:.4px;padding-bottom:2px}
  .layrowlbl{font-size:10px;color:var(--muted);display:flex;align-items:center}
  /* redundancy / stripe diagram */
  .stripe{display:grid;gap:4px;margin:7px 0 4px}
  .chunk{border-radius:4px;padding:6px 3px;text-align:center;font-size:11px;font-weight:600;
    border:1px solid transparent;overflow:hidden}
  .chunk.data{background:#12324a;color:#7cc4ff;border-color:#1d4d70}
  .chunk.copy{background:#152232;color:#5b8fb8;border-color:#22364a;border-style:dashed}
  .chunk.parity{background:#3a2a12;color:#f0c07a;border-color:#5a4020}
  .chunk.none{background:var(--panel2);color:var(--muted)}
  .striplbl{font-size:10px;color:var(--muted);display:flex;align-items:center}
  .effbar{display:flex;height:20px;border-radius:5px;overflow:hidden;background:var(--panel2)}
  .effbar>span{display:block;height:100%}
  .ftol{font-size:12px;padding:2px 9px;border-radius:11px;font-weight:600}
  .ftol.ok{background:#12331c;color:#5fd47e}
  .ftol.none{background:#3a1518;color:#ff8b84}
  /* zoom popup */
  .modal{position:fixed;inset:0;background:rgba(0,0,0,.66);z-index:60;
    display:flex;align-items:center;justify-content:center;padding:26px}
  .modalbox{background:var(--panel);border:1px solid var(--border);border-radius:12px;
    width:min(1150px,95vw);padding:15px 18px 13px;box-shadow:0 18px 50px rgba(0,0,0,.5)}
  .modalhdr{display:flex;align-items:center;gap:12px;margin-bottom:10px}
  .modalhdr b{font-size:15px}
  .modalbody{height:56vh;min-height:220px;overflow:hidden;resize:vertical;
    background:var(--bg);border-radius:8px;padding:4px}
  #modalCanvas{width:100%;height:100%;display:block}
  #modalStats{margin-top:10px;font-size:12px}
  canvas.mini,#spark{cursor:zoom-in}
  .mini{width:100%;height:22px;display:block}
  .cellspark{display:flex;align-items:center;gap:8px}
  .cellspark canvas{flex:1;min-width:60px;background:var(--panel2);border-radius:3px}
  /* Fixed width, NOT min-width: a growing label would shrink the flex canvas
     next to it and make the graph itself visibly resize every update. */
  .cellspark span{width:56px;flex:none;text-align:right;font-size:12px;white-space:nowrap;overflow:hidden}
  .stack{display:flex;height:22px;border-radius:5px;overflow:hidden;background:var(--panel2)}
  .stack>span{display:block;height:100%;border-right:1px solid rgba(0,0,0,.35)}
  .stack>span:last-child{border-right:none}
  .mono{font-variant-numeric:tabular-nums}
  .muted{color:var(--muted)}
  .sec{margin-bottom:16px}
  #spark{width:100%;height:100%;display:block}
  .kspark{width:100%;height:28px;display:block;margin-top:8px}
  .two{grid-template-columns:1fr 1fr}
  @media(max-width:900px){.two{grid-template-columns:1fr}}
  .jobsempty{color:var(--muted);font-size:13px}
  /* per-panel close. Absolutely positioned so it never becomes a grid cell. */
  [data-panel]{position:relative}
  .pclose{position:absolute;top:7px;right:9px;width:21px;height:21px;line-height:20px;
    text-align:center;border-radius:50%;color:var(--muted);cursor:pointer;font-size:12px;
    opacity:0;transition:opacity .12s,background .12s;z-index:4;user-select:none}
  [data-panel]:hover>.pclose{opacity:.75}
  .pclose:hover{background:var(--bad);color:#fff;opacity:1!important}
  .pdrag{position:absolute;top:7px;right:34px;width:21px;height:21px;line-height:20px;
    text-align:center;border-radius:5px;color:var(--muted);cursor:grab;font-size:13px;
    opacity:0;transition:opacity .12s;z-index:4;user-select:none}
  [data-panel]:hover>.pdrag{opacity:.55}
  .pdrag:hover{opacity:1!important;background:var(--panel2)}
  .pdrag:active{cursor:grabbing}
  [data-panel].dragging{opacity:.45}
  [data-panel].dropinto{outline:2px dashed var(--accent);outline-offset:-2px;border-radius:10px}
  /* !important so it beats the inline display the render code sets */
  .panel-closed{display:none!important}
  /* Stat lines truncate instead of wrapping — a wrap changes the row height and
     shifts every graph below it. Full text stays available via the title attr. */
  .tierrow>div:first-child,.tmrow>div:first-child{flex-wrap:nowrap!important}
  .t-stats,.s-stats,.tm-stats,.tm-extra,.t-count,.s-sub,.tm-sub{
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
  .tierrow{min-height:70px}
  .tmrow{min-height:116px}
  #tmSummary{min-height:32px}
  #diskTbl .e-name,#diskTbl .e-sub{display:block;white-space:nowrap;overflow:hidden;
    text-overflow:ellipsis;max-width:220px}
  #feeds{white-space:nowrap}
  /* KPI tiles are panels too, so their close/drag controls need to be smaller
     and tucked in tighter than a full card's. */
  .card.kpi>.pclose{top:5px;right:6px;width:18px;height:18px;line-height:17px;font-size:11px}
  .card.kpi>.pdrag{top:5px;right:27px;width:18px;height:18px;line-height:17px;font-size:11px}
  .right{text-align:right}
</style>
</head>
<body>
<div class="modal" id="modal" style="display:none">
  <div class="modalbox">
    <div class="modalhdr">
      <b id="modalTitle"></b>
      <span class="status muted" style="flex:1">double-click any graph to zoom · Esc or ✕ to close · drag the bottom edge to resize</span>
      <span class="fclear" id="modalClose" title="close">✕</span>
    </div>
    <div class="modalbody"><canvas id="modalCanvas"></canvas></div>
    <div id="modalStats" class="status"></div>
  </div>
</div>
<header>
  <h1>💾 Storage Spaces Dashboard</h1>
  <span class="hostchip" title="Server this dashboard is reading">__HOST__</span>
  <span id="filterChip" style="display:none"></span>
  <span style="flex:1"></span>
  <span id="tempUnit" class="status" title="Switch temperature units" style="cursor:pointer;user-select:none;
    border:1px solid var(--border);border-radius:12px;padding:2px 10px">°C</span>
  <span id="feeds" class="status mono"></span>
  <span id="clock" class="status mono"></span>
  <span id="conn" class="status"></span>
</header>

<div class="shell">
<nav class="side" id="nav">
  <div class="navsec">Live</div>
  <div class="navitem active" data-group="overview">📊 Overview</div>
  <div class="navitem" data-group="drives">💽 Drives <span class="ndot" id="ndDrives"></span><span class="nb" id="nbDrives"></span></div>
  <div class="navitem" data-group="cache">⚡ Cache</div>
  <div class="navsec">Configuration</div>
  <div class="navitem" data-group="capacity">📦 Capacity <span class="ndot" id="ndCap"></span><span class="nb" id="nbCap"></span></div>
  <div class="navitem" data-group="resiliency">🛡️ Resiliency <span class="ndot" id="ndRes"></span></div>
  <div class="navitem" data-group="jobs">🔧 Jobs <span class="nb" id="nbJobs"></span></div>
  <div class="navsec" id="restoreSec" style="display:none">Hidden panels</div>
  <div class="navitem" id="restorePanels" style="display:none" title="Show every hidden panel again">↩️ Restore all <span class="nb" id="nbHidden"></span></div>
</nav>
<main class="wrap" id="content">

<section data-group="overview">
  <div class="grid kpis">
    <div class="card kpi" data-panel="kpi-read"><h2>Total Read</h2><div><span class="v mono" id="kRead">–</span><span class="u">MB/s</span></div><div class="sub" id="kReadSub"></div><canvas class="kspark" id="kReadSpark"></canvas></div>
    <div class="card kpi" data-panel="kpi-write"><h2>Total Write</h2><div><span class="v mono" id="kWrite">–</span><span class="u">MB/s</span></div><div class="sub" id="kWriteSub"></div><canvas class="kspark" id="kWriteSpark"></canvas></div>
    <div class="card kpi" data-panel="kpi-iops"><h2>Total IOPS</h2><div><span class="v mono" id="kIops">–</span></div><div class="sub" id="kIopsSub"></div><canvas class="kspark" id="kIopsSpark"></canvas></div>
    <div class="card kpi" data-panel="kpi-wbc"><h2>Write-back Cache</h2><div><span class="v mono" id="kCache">–</span></div><div class="sub" id="kCacheSub">virtual disk WBC</div></div>
    <div class="card kpi" data-panel="kpi-cpu"><h2>CPU</h2><div><span class="v mono" id="kCpu">–</span><span class="u">%</span></div><div class="sub">parity is CPU-bound</div><canvas class="kspark" id="kCpuSpark"></canvas></div>
    <div class="card kpi" data-panel="kpi-iosize"><h2>Avg I/O Size</h2><div><span class="v mono" id="kIoSize">–</span></div><div class="sub" id="kIoSizeSub">read / write</div><canvas class="kspark" id="kIoSizeSpark"></canvas></div>
    <div class="card kpi" data-panel="kpi-mix"><h2>Read / Write Mix</h2><div><span class="v mono" id="kMix">–</span></div><div class="sub" id="kMixSub">share of IOPS</div><canvas class="kspark" id="kMixSpark"></canvas></div>
  </div>

  <div class="card sec" data-panel="throughput">
    <h2>Throughput (last ~2 min) <span class="muted" style="text-transform:none;letter-spacing:0">· drag the bottom edge to resize</span></h2>
    <div class="pbody" data-pk="spark" style="height:110px;overflow:hidden">
      <canvas id="spark"></canvas>
    </div>
    <div class="status" style="margin-top:6px">
      <span class="dot" style="background:var(--read)"></span>Read
      <span class="dot" style="background:var(--write);margin-left:12px"></span>Write
    </div>
  </div>

  <div class="card sec" id="tierActWrap" data-panel="tierAct" style="display:none">
    <h2>Tier Activity — realtime (physical media grouped by tier)</h2>
    <div class="pbody" data-pk="tierAct" id="tierAct" style="height:190px"></div>
  </div>

  <div class="card sec" id="spaceActWrap" data-panel="spaces" style="display:none">
    <h2>Virtual Disks (Spaces) — realtime I/O <span class="muted" style="text-transform:none;letter-spacing:0">· volume-level traffic, fans out to the drives below</span></h2>
    <div class="pbody" data-pk="spaceAct" id="spaceAct" style="height:190px"></div>
  </div>

</section>

<section data-group="drives" hidden>
  <div class="grid kpis">
    <div class="card kpi" data-panel="kpi-drives"><h2>Drives</h2><div><span class="v mono" id="kDrives">–</span></div><div class="sub" id="kDrivesSub"></div></div>
    <div class="card kpi" data-panel="kpi-health"><h2>Health</h2><div><span class="v mono" id="kHealth">–</span></div><div class="sub" id="kHealthSub"></div></div>
    <div class="card kpi" data-panel="kpi-temp"><h2>Hottest Drive</h2><div><span class="v mono" id="kTemp">–</span><span class="u" id="kTempUnit">°C</span></div><div class="sub" id="kTempSub"></div></div>
    <div class="card kpi" data-panel="kpi-wear"><h2>Max Wear</h2><div><span class="v mono" id="kWear">–</span><span class="u">%</span></div><div class="sub" id="kWearSub"></div></div>
    <div class="card kpi" data-panel="kpi-split"><h2>Split I/O</h2><div><span class="v mono" id="kSplit">–</span><span class="u">/s</span></div><div class="sub">fragmented / straddling I/O</div></div>
  </div>

  <div class="card sec" data-panel="diskTable">
    <h2>Physical Disks — activity &amp; status</h2>
    <div class="pbody" data-pk="disks" style="height:430px">
    <table id="diskTbl"><thead><tr>
      <th>Disk</th><th>Type</th><th>Usage</th><th style="width:17%">Busy %</th>
      <th style="width:19%">Throughput R/W MB/s</th>
      <th class="right">IOPS</th><th class="right">Queue</th><th class="right">Lat R/W ms</th>
      <th class="right">Size</th><th class="right">Wear/Temp</th><th>Health</th>
    </tr></thead><tbody></tbody></table>
    </div>
  </div>

</section>

<section data-group="capacity" hidden>
  <div class="grid kpis" id="poolKpis" data-panel="poolStats"></div>

  <div class="card sec" id="poolOverviewWrap" data-panel="poolOverview" style="display:none">
    <h2>Storage Pool <span class="muted" style="text-transform:none;letter-spacing:0">· allocation across the pool</span></h2>
    <div id="poolOverview"></div>
  </div>

  <div class="grid two sec">
    <div class="card" data-panel="pools">
      <h2>Pools &amp; Virtual Disks <span class="muted" style="text-transform:none;letter-spacing:0">· click to filter</span></h2>
      <div class="pbody" data-pk="pools" style="height:230px">
      <table id="poolTbl"><thead><tr><th>Name</th><th style="width:40%">Used</th><th class="right">Size</th><th>Health</th></tr></thead><tbody></tbody></table>
      </div>
    </div>
    <div class="card" data-panel="volumes">
      <h2>Volumes — free space</h2>
      <div class="pbody" data-pk="vols" style="height:230px">
      <table id="volTbl"><thead><tr><th>Volume</th><th style="width:40%">Used</th><th class="right">Free</th><th class="right">Size</th></tr></thead><tbody></tbody></table>
      </div>
    </div>
  </div>

  <div class="card sec" id="tierCompWrap" data-panel="tierComp" style="display:none">
    <h2>Tiered Virtual Disks — composition</h2>
    <div class="pbody" data-pk="tierComp" id="tierComp" style="height:200px"></div>
  </div>

  <div class="card sec" data-panel="tiers">
    <h2>Storage Tiers</h2>
    <div class="pbody" data-pk="tiers" id="tiers" style="height:120px"></div>
  </div>
</section>

<section data-group="resiliency" hidden>
  <div class="card sec" id="redunWrap" data-panel="redundancy" style="display:none">
    <h2>Data Redundancy — how a stripe is written</h2>
    <div id="redunSummary" style="margin-bottom:12px"></div>
    <div class="pbody" data-pk="redun" id="redun" style="height:330px"></div>
  </div>

  <div class="card sec" id="layoutWrap" data-panel="layout" style="display:none">
    <h2>Data Layout — tiers, columns &amp; drives</h2>
    <div class="pbody" data-pk="layout" id="layout" style="height:340px"></div>
  </div>

  <div class="card sec" id="repairWrap" data-panel="repair" style="display:none">
    <h2>Repair &amp; Regeneration <span class="muted" style="text-transform:none;letter-spacing:0">· from Storage Spaces internal counters</span></h2>
    <div id="repair"></div>
  </div>
</section>

<section data-group="cache" hidden>
  <div class="card sec" id="wcWrap" data-panel="writeCache">
    <h2>Storage Spaces Write-back Cache</h2>
    <div id="wcBody"><span class="muted">No write-back cache instances reported.</span></div>
  </div>

  <div class="card sec" data-panel="fileCache">
    <h2>Windows File Cache <span class="muted" style="text-transform:none;letter-spacing:0">· RAM used to cache file data</span></h2>
    <div class="grid kpis" style="margin-bottom:0">
      <div class="card kpi" style="background:var(--panel2)"><h2>System Cache</h2><div><span class="v mono" id="kMemCache">–</span></div><div class="sub">Memory\Cache Bytes</div></div>
      <div class="card kpi" style="background:var(--panel2)"><h2>Standby Cache</h2><div><span class="v mono" id="kMemStandby">–</span></div><div class="sub">reclaimable cached pages</div></div>
      <div class="card kpi" style="background:var(--panel2)"><h2>Modified Pages</h2><div><span class="v mono" id="kMemMod">–</span></div><div class="sub">dirty, awaiting write</div></div>
      <div class="card kpi" style="background:var(--panel2)"><h2>Available RAM</h2><div><span class="v mono" id="kMemAvail">–</span></div><div class="sub">free for cache growth</div></div>
    </div>
  </div>

  <div class="card sec" id="tierMoveWrap" data-panel="tierMove" style="display:none">
    <h2>Tier Optimisation <span class="muted" style="text-transform:none;letter-spacing:0">· data moving between tiers · double-click a graph to zoom</span></h2>
    <div id="tmSummary" style="font-size:12px;margin-bottom:12px"></div>
    <div class="pbody" data-pk="tierMove" id="tierMove" style="height:300px"></div>
  </div>
</section>

<section data-group="jobs" hidden>
  <div class="card sec" data-panel="jobs">
    <h2>Active Storage Jobs <span class="muted" style="text-transform:none;letter-spacing:0">· repair, rebalance, tier optimisation</span></h2>
    <div id="jobs" class="jobsempty">No active storage jobs.</div>
  </div>
</section>

</main>
</div>

<script>
// Cadences injected by the server from -PollMs / -TopologyMs.
const CFG = { pollMs: __POLL_MS__, topologyMs: __TOPO_MS__, systemMs: __SYS_MS__,
              historyMs: 120000, sysHistoryMs: 1800000 };
const $ = s => document.querySelector(s);
const fmtBytes = (b,d=1)=>{ if(b==null)return '–'; if(Math.abs(b)<1)return '0 B';
  const u=['B','KB','MB','GB','TB','PB']; let i=0,x=Math.abs(b);
  while(x>=1024&&i<u.length-1){x/=1024;i++;} return (b<0?'-':'')+x.toFixed(d)+' '+u[i]; };
const mbps = b => (b/1048576);
const num = (n,d=0)=> n==null?'–':Number(n).toLocaleString(undefined,{maximumFractionDigits:d});
// Order matters: "Unhealthy" CONTAINS "healthy", so the bad/warn patterns must be
// tested FIRST or an unhealthy drive renders green.
const isBadHealth  = h => /unhealth|fail|error|lost|missing|dead/i.test(h||'');
const isWarnHealth = h => /warn|degrad|incomplete|repair|rebuild/i.test(h||'');
const isOkHealth   = h => !isBadHealth(h) && !isWarnHealth(h) && /healthy|ok/i.test(h||'');
const healthColor = h => isBadHealth(h)?'var(--bad)'
                       : isWarnHealth(h)?'var(--warn)'
                       : isOkHealth(h)?'var(--good)':'var(--muted)';
const busyColor = p => p>=90?'var(--bad)':p>=70?'var(--warn)':'var(--good)';
function bar(pct,color,label){ pct=Math.max(0,Math.min(100,pct));
  return `<div class="bar"><span style="width:${pct}%;background:${color}"></span><em>${label??pct.toFixed(0)+'%'}</em></div>`; }
function healthDot(h){ return `<span class="dot" style="background:${healthColor(h)}"></span>${h||'–'}`; }
function typeTag(t){ const c=/ssd/i.test(t)?'ssd':/hdd/i.test(t)?'hdd':/scm/i.test(t)?'scm':/space/i.test(t)?'space':'';
  return `<span class="tag ${c}">${t||'?'}</span>`; }
// A "tier" is only real pool media. RAID logical drives, boot devices and the
// virtual disks themselves are NOT tiers — lumping them in produced the bogus
// "Unspecified"/"Unknown" tiers and made a Space look like the busiest drive.
// ---- temperature units (drives report °C; display is user preference) -------
let tempF=false;
try{ tempF = localStorage.getItem('ssdash.tempF')==='1'; }catch(e){}
const tempVal  = c => (c==null?null:(tempF ? c*9/5+32 : c));
const tempUnit = () => tempF ? '°F' : '°C';
const tempStr  = c => (c==null?'–':Math.round(tempVal(c))+tempUnit());
function initTempToggle(){
  const el=$('#tempUnit'); if(!el) return;
  const paint=()=>{ el.textContent=tempUnit(); };
  paint();
  el.addEventListener('click',()=>{
    tempF=!tempF;
    try{ localStorage.setItem('ssdash.tempF', tempF?'1':'0'); }catch(e){}
    paint();
    diskKey=null;                 // force the disk table to re-render its cells
    if(lastTopoData) applyTopoDerived(lastTopoData);
  });
}

const tierOf     = m => /ssd/i.test(m)?'SSD':/hdd/i.test(m)?'HDD':/scm/i.test(m)?'SCM':null;
const isPoolMedia= x => x.kind==='physical' && tierOf(x.mediaType)!==null;
function niceMax(v){ if(!(v>0)) return 1;
  const e=Math.pow(10,Math.floor(Math.log10(v))), m=v/e;
  return (m<=1?1:m<=2?2:m<=5?5:10)*e; }

// ---- history / smoothing ----------------------------------------------------
// At ~100ms the instantaneous values are far too jittery to read, so every
// number is displayed as a short moving average while the sparkline carries
// the full-resolution detail.
const MAXH   = Math.max(60, Math.round(CFG.historyMs/CFG.pollMs));  // ~2 min window
const SMOOTH = Math.max(3,  Math.round(500/CFG.pollMs));            // ~500ms average
const histR=[], histW=[], histI=[];
const histRSz=[], histWSz=[], histMix=[];   // avg I/O size (bytes) and read share (%)
function push(arr,v){ arr.push(v); if(arr.length>MAXH) arr.shift(); }
function avgLast(arr,n){ const m=Math.min(n||SMOOTH,arr.length); if(!m) return 0;
  let s=0; for(let i=arr.length-m;i<arr.length;i++) s+=arr[i]; return s/m; }
function maxOf(arr){ let m=0; for(const v of arr) if(v>m) m=v; return m; }
// Canvas strokeStyle cannot resolve "var(--x)" — it needs a real color value.
const cssVar   = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const colorFor = p => p>=90?cssVar('--bad'):p>=70?cssVar('--warn'):cssVar('--good');

// latest per-disk status from /api/topology, keyed by OS disk number, merged
// into the realtime disk table so activity + status live in one view.
let topoDisks={};
// feed health — makes a stalled background collector visible instead of just
// leaving half the dashboard mysteriously blank.
let lastTopoAt=0, layoutState='pending', wearState='pending', poolState='pools —';
let topoReady=false;   // false until the storage collector has published real data
let topoDiag=null;     // {mapMs,passMs,drives} — how slow the storage scan really is

// ---- left nav: show one group at a time ------------------------------------
// Hidden sections also skip all canvas work (see visible()), so switching away
// from the drive table is a real CPU saving on a large array.
const visible = el => !!(el && el.offsetParent!==null);

// Health surfaced on the nav so a failed drive is visible from any tab.
// level: 'bad' | 'warn' | null
function setNavHealth(sel, level, title){
  const dot=document.querySelector(sel); if(!dot) return;
  dot.className='ndot'+(level?(' '+level):'');
  dot.title=title||'';
  const item=dot.closest('.navitem');
  if(item){
    item.classList.toggle('alert', level==='bad');
    item.classList.toggle('warnstate', level==='warn');
    if(title) item.title=title; else item.removeAttribute('title');
  }
}
const worstOf = list => {
  const bad =list.filter(isBadHealth), warn=list.filter(isWarnHealth);
  return bad.length?{level:'bad',n:bad.length}:(warn.length?{level:'warn',n:warn.length}:{level:null,n:0});
};
let navGroup='overview';
function setGroup(g){
  navGroup=g;
  document.querySelectorAll('#nav .navitem').forEach(n=>n.classList.toggle('active',n.dataset.group===g));
  document.querySelectorAll('main section[data-group]').forEach(s=>{ s.hidden = s.dataset.group!==g; });
  try{ localStorage.setItem('ssdash.group',g); }catch(e){}
  drawSpark();             // freshly shown canvases need an immediate paint
}
function initNav(){
  // [data-group] only — the "Restore all" item is a .navitem too, and wiring it
  // here made it call setGroup(undefined), which hid every section.
  document.querySelectorAll('#nav .navitem[data-group]')
    .forEach(n=>n.addEventListener('click',()=>setGroup(n.dataset.group)));
  let g='overview';
  try{ g=localStorage.getItem('ssdash.group')||'overview'; }catch(e){}
  if(!document.querySelector(`main section[data-group="${g}"]`)) g='overview';
  setGroup(g);
}

// ---- per-panel close (persists across reloads) -----------------------------
// Hidden panels also stop rendering: visible() returns false for them, so their
// canvases and tables are skipped entirely.
let closedPanels=new Set();
try{ closedPanels=new Set(JSON.parse(localStorage.getItem('ssdash.closed')||'[]')); }catch(e){}
function persistClosed(){ try{ localStorage.setItem('ssdash.closed',JSON.stringify([...closedPanels])); }catch(e){} }
function applyClosed(){
  document.querySelectorAll('[data-panel]').forEach(el=>
    el.classList.toggle('panel-closed', closedPanels.has(el.dataset.panel)));
  const n=closedPanels.size;
  const r=$('#restorePanels'), s=$('#restoreSec'), b=$('#nbHidden');
  if(r) r.style.display = n?'':'none';
  if(s) s.style.display = n?'':'none';
  if(b) b.textContent = n||'';
}
// Writing innerHTML on a panel wipes any controls injected into it, so button
// creation is idempotent and can be re-run after a re-render.
function addCloseBtn(el){
  if(!el || el.querySelector(':scope > .pclose')) return;
  const b=document.createElement('span');
  b.className='pclose'; b.textContent='✕';
  b.title='Hide this panel';
  b.addEventListener('click',e=>{
    e.stopPropagation();              // panels can sit inside click-to-filter targets
    closedPanels.add(el.dataset.panel); persistClosed(); applyClosed();
  });
  el.appendChild(b);
}
function ensurePanelControls(el){ addCloseBtn(el); addDragHandle(el); }
function initPanelClose(){
  document.querySelectorAll('[data-panel]').forEach(addCloseBtn);
  const r=$('#restorePanels');
  if(r) r.addEventListener('click',()=>{
    closedPanels.clear(); persistClosed(); applyClosed();
    if(origOrder){ applyOrder(origOrder); saveOrder(); }   // also reset the layout
    drawSpark();
  });
  applyClosed();
}

// ---- drag-to-reorder panels ------------------------------------------------
// Panels only reorder within their own container, so a card in a two-up grid
// stays in that grid rather than escaping into the section.
let dragKey=null, origOrder=null;
function panelOrder(){ return [...document.querySelectorAll('[data-panel]')].map(x=>x.dataset.panel); }
function applyOrder(keys){
  (keys||[]).forEach(k=>{
    const el=document.querySelector(`[data-panel="${k}"]`);
    if(el&&el.parentElement) el.parentElement.appendChild(el);   // re-append in saved order
  });
}
function saveOrder(){ try{ localStorage.setItem('ssdash.order',JSON.stringify(panelOrder())); }catch(e){} }
function initPanelOrder(){
  origOrder=panelOrder();                                   // snapshot BEFORE restoring
  let saved=[]; try{ saved=JSON.parse(localStorage.getItem('ssdash.order')||'[]'); }catch(e){}
  if(saved.length) applyOrder(saved);

  document.querySelectorAll('[data-panel]').forEach(addDragHandle);
}
function addDragHandle(el){
    if(!el) return;
    if(!el.querySelector(':scope > .pdrag')){
      const h=document.createElement('span');
      h.className='pdrag'; h.textContent='⠿'; h.title='Drag to reorder';
      // draggable is enabled only while grabbing the handle, so text selection and
      // the panel resize grip keep working normally.
      h.addEventListener('mousedown',()=>el.setAttribute('draggable','true'));
      h.addEventListener('mouseup',  ()=>el.removeAttribute('draggable'));
      el.appendChild(h);
    }
    if(el._dndWired) return;          // element listeners survive innerHTML writes
    el._dndWired=true;

    el.addEventListener('dragstart',e=>{
      dragKey=el.dataset.panel; el.classList.add('dragging');
      if(e.dataTransfer){ e.dataTransfer.effectAllowed='move';
        try{ e.dataTransfer.setData('text/plain',dragKey); }catch(_){} }
    });
    el.addEventListener('dragend',()=>{
      el.classList.remove('dragging'); el.removeAttribute('draggable'); dragKey=null;
      document.querySelectorAll('.dropinto').forEach(x=>x.classList.remove('dropinto'));
      saveOrder();
    });
    el.addEventListener('dragover',e=>{
      if(!dragKey||dragKey===el.dataset.panel) return;
      const src=document.querySelector(`[data-panel="${dragKey}"]`);
      if(!src||src.parentElement!==el.parentElement) return;   // same container only
      e.preventDefault();
      el.classList.add('dropinto');
      const r=el.getBoundingClientRect();
      const after=(e.clientY-r.top)>r.height/2;
      el.parentElement.insertBefore(src, after?el.nextSibling:el);
    });
    el.addEventListener('dragleave',()=>el.classList.remove('dropinto'));
    el.addEventListener('drop',e=>{ e.preventDefault(); el.classList.remove('dropinto'); });
}

// ---- resizable panels (drag bottom edge); sizes persist across reloads -----
// Attach a chart spec to each fixed graph so double-click can zoom it. Specs
// reference the live ring buffers, so they never go stale.
const MBs=1/1048576;
function initChartSpecs(){
  const R=cssVar('--read'), W=cssVar('--write'), A=cssVar('--accent');
  const set=(sel,spec)=>setSpec($(sel),spec);
  set('#kReadSpark',  {title:'Total Read',       unit:'MB/s', scale:MBs, series:[{data:histR,color:R,fill:'rgba(74,163,255,.16)',label:'Read'}]});
  set('#kWriteSpark', {title:'Total Write',      unit:'MB/s', scale:MBs, series:[{data:histW,color:W,fill:'rgba(188,140,255,.16)',label:'Write'}]});
  set('#kIopsSpark',  {title:'Total IOPS',       unit:'IOPS',            series:[{data:histI,color:A,fill:'rgba(74,163,255,.16)',label:''}]});
  set('#spark',       {title:'Total Throughput — all pool media', unit:'MB/s', scale:MBs, series:[
    {data:histR,color:R,fill:'rgba(74,163,255,.13)',label:'Read'},
    {data:histW,color:W,fill:'rgba(188,140,255,.13)',label:'Write'}]});
  set('#kIoSizeSpark', {title:'Average I/O size', unit:'KB', scale:1/1024, series:[
    {data:histRSz,color:R,label:'Read'},{data:histWSz,color:W,label:'Write'}]});
  set('#kMixSpark',    {title:'Read / write balance', unit:'%', max:100, signed:true,
    fmtLabel:v=>Math.abs(v)<0.5?'even':(Math.abs(v).toFixed(0)+'% '+(v>0?'read':'write')),
    series:[{data:histMix,color:cssVar('--muted'),
      fill:'rgba(74,163,255,.30)', fillNeg:'rgba(188,140,255,.30)', label:'Read bias'}]});
  // CPU is sampled on the 1s system loop, so it needs the long window and its
  // own time scale — otherwise the zoom would label 30 min of data as 2 min.
  set('#kCpuSpark', {title:'CPU utilisation', unit:'%', max:100, maxPoints:SYSH, sampleMs:CFG.systemMs,
    series:[{data:histCpu,color:cssVar('--good'),fill:busyFill(0),label:'CPU'}]});
  $('#modalClose').onclick=closeModal;
  $('#modal').addEventListener('click',e=>{ if(e.target.id==='modal') closeModal(); });
}

function initPanels(){
  const K=pk=>'ssdash.panel.'+pk;
  const all=()=>document.querySelectorAll('.pbody[data-pk]');
  all().forEach(el=>{
    try{ const s=localStorage.getItem(K(el.dataset.pk)); if(s) el.style.height=s; }catch(e){}
  });
  const save=()=>{ all().forEach(el=>{
    if(el.style.height){ try{ localStorage.setItem(K(el.dataset.pk),el.style.height); }catch(e){} } }); };
  // A CSS resize drag always ends in a mouse/pointer-up. ResizeObserver is NOT
  // reliable in every embedding context (it never fires in a non-painting tab),
  // so persistence hangs off the pointer events instead.
  document.addEventListener('mouseup',   ()=>setTimeout(save,60));
  document.addEventListener('pointerup', ()=>setTimeout(save,60));
  window.addEventListener('beforeunload', save);
}

// ---- click-to-filter: scope the whole dashboard to one pool or space -------
let filter=null;                       // {type:'pool'|'space', key, label}
let filterSets={pool:{},space:{}};     // name -> Set(diskNumber) from /api/topology
function filterDisks(list){
  if(!filter) return list;
  const s=(filterSets[filter.type]||{})[filter.key];
  return s ? list.filter(x=>s.has(String(x.diskNumber))) : list;
}
function resetSeries(){
  histR.length=0; histW.length=0; histI.length=0;
  histRSz.length=0; histWSz.length=0; histMix.length=0;
  diskKey=null; tierKey=null; spaceKey=null;   // force table/card rebuild
}
function setFilter(type,key,label){
  if(filter && filter.type===type && filter.key===key){ clearFilter(); return; }
  filter={type,key,label:label||key};
  resetSeries(); renderFilterChip(); markActive();
}
function clearFilter(){ filter=null; resetSeries(); renderFilterChip(); markActive(); }
function renderFilterChip(){
  const el=$('#filterChip');
  if(!filter){ el.style.display='none'; el.innerHTML=''; return; }
  el.style.display='';
  el.innerHTML=`<span>${filter.type}: <b>${filter.label}</b></span><span class="fclear" title="clear filter">✕</span>`;
  el.querySelector('.fclear').onclick=e=>{ e.stopPropagation(); clearFilter(); };
}
function markActive(){
  document.querySelectorAll('[data-ft]').forEach(el=>{
    const on = filter && el.dataset.ft===filter.type && el.dataset.fk===filter.key;
    el.classList.toggle('factive', !!on);
  });
}
document.addEventListener('click',e=>{
  // Graphs live INSIDE filter targets (e.g. the Spaces rows). A single click on
  // one would apply the filter and rebuild the card, so the second click of a
  // double-click never landed. Canvases are zoom-only; filter from the row text.
  if(e.target.closest('canvas')) return;
  const t=e.target.closest('[data-ft]');
  if(t) setFilter(t.dataset.ft, t.dataset.fk, t.dataset.fl||t.dataset.fk);
});

// Generic sparkline. series: [{data:[],color,fill}]. fixedMax pins the y-scale
// (used for 0-100% busy); otherwise it autoscales to the window's peak.
// `signed` draws a diverging chart: zero sits on the midline and values deviate
// up or down, with each half filled in its own colour (s.fill / s.fillNeg).
function drawMini(cv, series, fixedMax, h, maxPoints, signed){
  if(!cv) return;
  const MP = maxPoints || MAXH;
  const dpr=devicePixelRatio||1;
  const cw=cv.clientWidth||120, ch=h||cv.clientHeight||22;
  const W=cv.width=Math.max(1,Math.round(cw*dpr)), H=cv.height=Math.max(1,Math.round(ch*dpr));
  const ctx=cv.getContext('2d'); ctx.clearRect(0,0,W,H);
  let max=fixedMax;
  if(!max){ max=1; for(const s of series){
    for(const v of s.data){ const a=Math.abs(v); if(a>max) max=a; } } }
  const step=W/Math.max(MP-1,1), pad=1.5*dpr;
  const zeroY = signed ? H/2 : H;

  if(signed){                                   // midline
    ctx.strokeStyle=cssVar('--border'); ctx.lineWidth=1*dpr;
    ctx.beginPath(); ctx.moveTo(0,zeroY); ctx.lineTo(W,zeroY); ctx.stroke();
  }
  for(const s of series){
    if(!s.data.length) continue;
    const off=MP-s.data.length;                // right-align: newest at right edge
    const y = signed
      ? v => zeroY - (Math.max(-max,Math.min(max,v))/max)*(H/2-pad)
      : v => H-(Math.min(v,max)/max)*(H-2*pad)-pad;
    const trace=()=>{ ctx.beginPath();
      for(let i=0;i<s.data.length;i++){ const x=(off+i)*step;
        i?ctx.lineTo(x,y(s.data[i])):ctx.moveTo(x,y(s.data[i])); } };
    const fillTo=(col)=>{ trace();
      ctx.lineTo((off+s.data.length-1)*step,zeroY); ctx.lineTo(off*step,zeroY);
      ctx.closePath(); ctx.fillStyle=col; ctx.fill(); };
    if(signed && (s.fill||s.fillNeg)){
      if(s.fill){ ctx.save(); ctx.beginPath(); ctx.rect(0,0,W,zeroY); ctx.clip(); fillTo(s.fill); ctx.restore(); }
      if(s.fillNeg){ ctx.save(); ctx.beginPath(); ctx.rect(0,zeroY,W,H-zeroY); ctx.clip(); fillTo(s.fillNeg); ctx.restore(); }
    } else if(s.fill){ fillTo(s.fill); }
    trace(); ctx.strokeStyle=s.color; ctx.lineWidth=1.4*dpr; ctx.stroke();
  }
}
// Full chart with a real y-axis (auto-scaled to a "nice" peak), gridlines and a
// time axis. Driven by a spec so the inline chart and the zoom popup share one
// implementation:  {title, series:[{data,color,fill,label}], unit, scale, max}
// `scale` converts raw samples to display units (bytes/s -> MB/s);
// `max` pins the axis (e.g. 100 for a percentage).
function drawChart(cv, spec){
  if(!cv||!spec||!spec.series) return;
  // Series sampled at different cadences (100ms disk vs 1s system) need their
  // own window length and time-axis scale.
  const MP = spec.maxPoints || MAXH;
  const sampleMs = spec.sampleMs || CFG.pollMs;
  const dpr=devicePixelRatio||1;
  const ch=Math.max(40, cv.clientHeight||110);
  const W=cv.width=Math.max(1,Math.round((cv.clientWidth||600)*dpr));
  const H=cv.height=Math.round(ch*dpr);
  const ctx=cv.getContext('2d'); ctx.clearRect(0,0,W,H);

  const sc=spec.scale||1, signed=!!spec.signed;
  let maxDisp=spec.max;
  if(maxDisp==null){ let p=0;
    spec.series.forEach(s=>{ for(const v of s.data){ const a=Math.abs(v)*sc; if(a>p)p=a; } });
    maxDisp=niceMax(p); }
  const maxRaw=(maxDisp/sc)||1;

  const padL=Math.round(64*dpr), padT=Math.round(6*dpr), padB=Math.round(16*dpr);
  const plotW=W-padL, plotH=H-padT-padB;
  const grid=cssVar('--border'), muted=cssVar('--muted');
  const dec=maxDisp<10?1:0, dense=ch>=150;
  ctx.font=`${10*dpr}px "Segoe UI",system-ui,sans-serif`;

  // gridlines + value labels (taller chart => label every line).
  // Signed charts run -max..+max with zero on the midline.
  const zeroY = signed ? padT+plotH/2 : padT+plotH;
  const lab = v => spec.fmtLabel ? spec.fmtLabel(v)
                                 : v.toFixed(dec)+(spec.unit?' '+spec.unit:'');
  ctx.textAlign='right'; ctx.textBaseline='middle';
  const ticks = signed ? [-1,-0.5,0,0.5,1] : [0,0.25,0.5,0.75,1];
  ticks.forEach(f=>{
    const y = signed ? zeroY - f*(plotH/2) : padT+plotH-f*plotH;
    const mid = signed ? f===0 : false;
    ctx.strokeStyle = mid ? muted : grid; ctx.lineWidth = (mid?1.2:1)*dpr;
    ctx.beginPath(); ctx.moveTo(padL,y); ctx.lineTo(W,y); ctx.stroke();
    if(dense || mid || Math.abs(f)===1 || (!signed && (f===0||f===0.5))){
      ctx.fillStyle=muted; ctx.fillText(lab(maxDisp*f), padL-7*dpr, y);
    }
  });

  // time axis
  const secs=(MP*sampleMs)/1000;
  ctx.fillStyle=muted; ctx.textBaseline='alphabetic';
  ctx.textAlign='left';  ctx.fillText('-'+(secs>=60?(secs/60).toFixed(0)+' min':secs.toFixed(0)+' s'), padL, H-4*dpr);
  ctx.textAlign='right'; ctx.fillText('now', W, H-4*dpr);

  const step=plotW/Math.max(MP-1,1);
  spec.series.forEach(s=>{
    const data=s.data; if(!data||data.length<2) return;
    const off=MP-data.length;
    const yv = signed
      ? v => zeroY - (Math.max(-maxRaw,Math.min(maxRaw,v))/maxRaw)*(plotH/2)
      : v => padT+plotH-(Math.min(v,maxRaw)/maxRaw)*plotH;
    const path=()=>{ ctx.beginPath();
      for(let i=0;i<data.length;i++){ const x=padL+(off+i)*step;
        i?ctx.lineTo(x,yv(data[i])):ctx.moveTo(x,yv(data[i])); } };
    const fillTo=(col)=>{ path();
      ctx.lineTo(padL+(off+data.length-1)*step, zeroY);
      ctx.lineTo(padL+off*step, zeroY);
      ctx.closePath(); ctx.fillStyle=col; ctx.fill(); };
    if(signed && (s.fill||s.fillNeg)){
      if(s.fill){ ctx.save(); ctx.beginPath(); ctx.rect(padL,padT,W-padL,zeroY-padT); ctx.clip(); fillTo(s.fill); ctx.restore(); }
      if(s.fillNeg){ ctx.save(); ctx.beginPath(); ctx.rect(padL,zeroY,W-padL,padT+plotH-zeroY); ctx.clip(); fillTo(s.fillNeg); ctx.restore(); }
    } else if(s.fill){ fillTo(s.fill); }
    path(); ctx.strokeStyle=s.color; ctx.lineWidth=1.6*dpr; ctx.stroke();
  });
}
function drawSpark(){ const cv=$('#spark'); if(cv&&cv._spec) drawChart(cv,cv._spec); }

// ---- zoom popup: double-click any graph ------------------------------------
// A spec holds references to the live ring buffers, so the popup keeps updating
// in realtime while it's open.
let modalSpec=null;
// Attach a spec + an accurate tooltip. Canvases don't participate in filtering,
// so the hint must say what a click there actually does.
function setSpec(cv,spec){
  if(!cv) return;
  cv._spec=spec;
  cv.title='Double-click to zoom'+(spec&&spec.title?(' · '+spec.title):'');
}
function openModal(spec){
  modalSpec=spec;
  $('#modalTitle').textContent=spec.title||'Chart';
  $('#modal').style.display='flex';
  drawModal();
}
function closeModal(){ modalSpec=null; $('#modal').style.display='none'; }
function drawModal(){
  if(!modalSpec) return;
  drawChart($('#modalCanvas'), modalSpec);
  const sc=modalSpec.scale||1, u=modalSpec.unit||'';
  $('#modalStats').innerHTML=modalSpec.series.map(s=>{
    const d=s.data||[], now=avgLast(d)*sc, pk=maxOf(d)*sc;
    let sum=0; for(const v of d) sum+=v;
    const avg=d.length?(sum/d.length)*sc:0;
    const f=v=>num(v, v<100?1:0);
    return `<span style="margin-right:20px"><span class="dot" style="background:${s.color}"></span>`
      +`${s.label||''} now <b>${f(now)}</b> ${u} · avg ${f(avg)} · peak ${f(pk)}</span>`;
  }).join('');
}
document.addEventListener('dblclick',e=>{
  const cv=e.target.closest('canvas');
  if(cv&&cv._spec) openModal(cv._spec);
});
document.addEventListener('keydown',e=>{ if(e.key==='Escape') closeModal(); });

// ---- disk table: build rows once, then update cells + redraw sparks in place --
// Rebuilding innerHTML 10x/sec would trash the canvases and burn CPU, so rows
// are only rebuilt when the set of disks actually changes.
const dHist={}; const diskEls={}; let diskKey=null;
function diskHist(dn){ const k=String(dn);
  return dHist[k]||(dHist[k]={busy:[],read:[],write:[],iops:[],queue:[],rlat:[],wlat:[]}); }
const busyFill = p => p>=90?'rgba(248,81,73,.18)':p>=70?'rgba(210,153,34,.18)':'rgba(63,185,80,.18)';

function renderDisks(disks){
  const tb=$('#diskTbl tbody');
  const key=disks.map(x=>x.diskNumber).join('|');
  if(key!==diskKey){
    diskKey=key;
    for(const k in diskEls) delete diskEls[k];
    if(!disks.length){ tb.innerHTML='<tr><td colspan="11" class="muted">No disk counters returned.</td></tr>'; return; }
    tb.innerHTML=disks.map(x=>`<tr data-dn="${x.diskNumber}">
      <td><b class="e-name"></b><div class="muted mono e-sub" style="font-size:11px"></div></td>
      <td class="e-type"></td>
      <td class="muted e-usage"></td>
      <td><div class="cellspark"><canvas class="mini e-busyc"></canvas><span class="mono e-busyv"></span></div></td>
      <td><div class="cellspark"><canvas class="mini e-thruc"></canvas><span class="mono e-thruv"></span></div></td>
      <td class="right mono e-iops"></td>
      <td class="right mono e-queue"></td>
      <td class="right mono e-lat"></td>
      <td class="right mono e-size"></td>
      <td class="right mono e-wear"></td>
      <td class="e-health"></td></tr>`).join('');
    tb.querySelectorAll('tr[data-dn]').forEach(tr=>{
      const q=s=>tr.querySelector(s);
      diskEls[tr.dataset.dn]={tr,name:q('.e-name'),sub:q('.e-sub'),type:q('.e-type'),usage:q('.e-usage'),
        busyc:q('.e-busyc'),busyv:q('.e-busyv'),thruc:q('.e-thruc'),thruv:q('.e-thruv'),
        iops:q('.e-iops'),queue:q('.e-queue'),lat:q('.e-lat'),size:q('.e-size'),
        wear:q('.e-wear'),health:q('.e-health')};
    });
  }
  const rc=cssVar('--read'), wc=cssVar('--write');
  // Viewport culling: an array with dozens of drives means dozens of canvases.
  // History is ALWAYS recorded, but we only repaint rows currently on screen.
  const cont=document.querySelector('.pbody[data-pk="disks"]');
  const shown=visible(cont);   // whole section hidden by the nav => no canvas work
  const vTop=cont?cont.scrollTop-80:-1e9, vBot=cont?cont.scrollTop+cont.clientHeight+80:1e9;
  disks.forEach(x=>{
    const e=diskEls[String(x.diskNumber)]; if(!e) return;
    const h=diskHist(x.diskNumber);
    push(h.busy,x.busy); push(h.read,x.readBps); push(h.write,x.writeBps);
    push(h.iops,x.reads+x.writes); push(h.queue,x.queue);
    push(h.rlat,x.readLatencyMs); push(h.wlat,x.writeLatencyMs);
    const st=topoDisks[String(x.diskNumber)], sb=avgLast(h.busy);

    const top=e.tr.offsetTop, vis=shown && (top+e.tr.offsetHeight)>vTop && top<vBot;
    // graphs carry the full-resolution signal
    // Specs are always attached (cheap, and keeps every graph zoomable even
    // before it has been painted); only the drawing is skipped when off-screen.
    const who=`${x.name} · #${x.diskNumber}`;
    setSpec(e.busyc,{title:who+' — Busy', unit:'%', max:100,
      series:[{data:h.busy,color:colorFor(sb),fill:busyFill(sb),label:'Busy'}]});
    setSpec(e.thruc,{title:who+' — Throughput', unit:'MB/s', scale:MBs, series:[
      {data:h.read,color:rc,fill:'rgba(74,163,255,.13)',label:'Read'},
      {data:h.write,color:wc,fill:'rgba(188,140,255,.13)',label:'Write'}]});
    if(vis){
      drawMini(e.busyc,[{data:h.busy,color:colorFor(sb),fill:busyFill(sb)}],100);
      drawMini(e.thruc,[{data:h.read,color:rc},{data:h.write,color:wc}]);
    }
    // numbers are smoothed so they're actually readable
    e.busyv.textContent=sb.toFixed(0)+'%'; e.busyv.style.color=busyColor(sb);
    e.thruv.textContent=mbps(avgLast(h.read)).toFixed(1)+' / '+mbps(avgLast(h.write)).toFixed(1);
    e.iops.textContent=num(avgLast(h.iops));
    e.queue.textContent=avgLast(h.queue).toFixed(2);
    e.lat.textContent=avgLast(h.rlat).toFixed(1)+'/'+avgLast(h.wlat).toFixed(1);

    // slow-changing cells: only touch the DOM when the value actually changes
    const bt=(st&&st.busType)||x.busType||'';
    const sub='#'+x.diskNumber+(bt?(' · '+bt):'')
      +(x.kind==='virtual'?' · space':'')+(x.isSystem?' · system':'');
    const usage=st?st.usage:'–', size=st?fmtBytes(st.size):'–';
    const wear=st?((st.wear==null?'–':st.wear+'%')+' / '+tempStr(st.tempC)):'–';
    const hv=x.health||(st?st.health:'');
    if(e._name!==x.name){ e.name.textContent=x.name; e._name=x.name; }
    if(e._sub!==sub){ e.sub.textContent=sub; e._sub=sub; }
    if(e._type!==x.mediaType){ e.type.innerHTML=typeTag(x.mediaType); e._type=x.mediaType; }
    if(e._usage!==usage){ e.usage.textContent=usage; e._usage=usage; }
    if(e._size!==size){ e.size.textContent=size; e._size=size; }
    if(e._wear!==wear){ e.wear.textContent=wear; e._wear=wear; }
    if(e._health!==hv){ e.health.innerHTML=healthDot(hv); e._health=hv; }
  });
}

// ---- tier activity: same build-once pattern, one graph per media tier -------
const tHist={}; const tierEls={}; let tierKey=null;
function tierHist(k){ return tHist[k]||(tHist[k]={busy:[],read:[],write:[],iops:[]}); }

function renderTierActivity(disks){
  const groups={};
  // Pool media only. Virtual disks are the SAME I/O one layer up (double count),
  // and RAID/boot devices aren't tier members at all.
  disks.filter(isPoolMedia).forEach(x=>{
    const k=tierOf(x.mediaType);
    const g=(groups[k]=groups[k]||{count:0,read:0,write:0,iops:0,busySum:0,queue:0});
    g.count++; g.read+=x.readBps; g.write+=x.writeBps; g.iops+=x.reads+x.writes;
    g.busySum+=x.busy; g.queue+=x.queue;
  });
  const order={SCM:0,SSD:1,HDD:2};
  const gk=Object.keys(groups).sort((a,b)=>(order[a]??9)-(order[b]??9));
  if(gk.length<1){ $('#tierActWrap').style.display='none'; return; }
  $('#tierActWrap').style.display='';

  const key=gk.join('|');
  if(key!==tierKey){
    tierKey=key;
    for(const k in tierEls) delete tierEls[k];
    $('#tierAct').innerHTML=gk.map(k=>`<div class="tierrow" data-tk="${k}" style="margin-bottom:16px">
      <div style="display:flex;justify-content:space-between;margin-bottom:5px;flex-wrap:wrap;gap:6px">
        <span>${typeTag(k)} <b>${k} tier</b> <span class="muted t-count"></span></span>
        <span class="mono muted t-stats"></span></div>
      <div class="cellspark"><canvas class="mini t-spark" style="height:36px"></canvas><span class="mono t-busy"></span></div>
    </div>`).join('');
    $('#tierAct').querySelectorAll('.tierrow').forEach(el=>{
      tierEls[el.dataset.tk]={count:el.querySelector('.t-count'),stats:el.querySelector('.t-stats'),
        spark:el.querySelector('.t-spark'),busy:el.querySelector('.t-busy')};
    });
  }
  gk.forEach(k=>{
    const g=groups[k], e=tierEls[k]; if(!e) return;
    const h=tierHist(k);
    push(h.busy,g.busySum/g.count); push(h.read,g.read); push(h.write,g.write); push(h.iops,g.iops);
    const sb=avgLast(h.busy);
    const cnt=g.count+' disk'+(g.count>1?'s':'');
    if(e._cnt!==cnt){ e.count.textContent=cnt; e._cnt=cnt; }
    e.stats.textContent=mbps(avgLast(h.read)).toFixed(1)+' ▼ / '+mbps(avgLast(h.write)).toFixed(1)
      +' ▲ MB/s · '+num(avgLast(h.iops))+' IOPS · peak '+maxOf(h.busy).toFixed(0)+'%';
    e.stats.title=e.stats.textContent;
    e.busy.textContent=sb.toFixed(0)+'%'; e.busy.style.color=busyColor(sb);
    drawMini(e.spark,[{data:h.busy,color:colorFor(sb),fill:busyFill(sb)}],100,36);
    setSpec(e.spark,{title:k+' tier — Busy (avg of '+g.count+' drives)', unit:'%', max:100,
      series:[{data:h.busy,color:colorFor(sb),fill:busyFill(sb),label:'Avg busy'}]});
  });
}

// ---- virtual disks (spaces): volume-level I/O, shown separately ------------
const sHist={}; const spaceEls={}; let spaceKey=null;
function spaceHist(k){ return sHist[k]||(sHist[k]={busy:[],read:[],write:[],iops:[]}); }

function renderSpaces(disks){
  const sp=disks.filter(x=>x.kind==='virtual');
  if(!sp.length){ $('#spaceActWrap').style.display='none'; return; }
  $('#spaceActWrap').style.display='';
  const key=sp.map(x=>x.diskNumber).join('|');
  if(key!==spaceKey){
    spaceKey=key;
    for(const k in spaceEls) delete spaceEls[k];
    $('#spaceAct').innerHTML=sp.map(x=>`<div class="tierrow" data-sk="${x.diskNumber}" data-ft="space" data-fk="${x.name}" title="Click to filter to this space" style="margin-bottom:16px;padding:4px">
      <div style="display:flex;justify-content:space-between;margin-bottom:5px;flex-wrap:wrap;gap:6px">
        <span><b>${x.name}</b> <span class="muted s-sub"></span></span>
        <span class="mono muted s-stats"></span></div>
      <div class="cellspark"><canvas class="mini s-spark" style="height:36px"></canvas><span class="mono s-busy"></span></div>
    </div>`).join('');
    $('#spaceAct').querySelectorAll('.tierrow').forEach(el=>{
      spaceEls[el.dataset.sk]={sub:el.querySelector('.s-sub'),stats:el.querySelector('.s-stats'),
        spark:el.querySelector('.s-spark'),busy:el.querySelector('.s-busy')};
    });
  }
  const rc=cssVar('--read'), wc=cssVar('--write');
  sp.forEach(x=>{
    const e=spaceEls[String(x.diskNumber)]; if(!e) return;
    const h=spaceHist(x.diskNumber);
    push(h.busy,x.busy); push(h.read,x.readBps); push(h.write,x.writeBps); push(h.iops,x.reads+x.writes);
    const sub='#'+x.diskNumber+(x.health?(' · '+x.health):'');
    if(e._sub!==sub){ e.sub.textContent=sub; e._sub=sub; }
    e.stats.textContent=mbps(avgLast(h.read)).toFixed(1)+' ▼ / '+mbps(avgLast(h.write)).toFixed(1)
      +' ▲ MB/s · '+num(avgLast(h.iops))+' IOPS · Q '+avgLast(h.busy).toFixed(0)+'% busy';
    const sb=avgLast(h.busy);
    e.busy.textContent=sb.toFixed(0)+'%'; e.busy.style.color=busyColor(sb);
    drawMini(e.spark,[{data:h.read,color:rc},{data:h.write,color:wc}],null,36);
    setSpec(e.spark,{title:x.name+' — Space I/O', unit:'MB/s', scale:MBs, series:[
      {data:h.read,color:rc,fill:'rgba(74,163,255,.13)',label:'Read'},
      {data:h.write,color:wc,fill:'rgba(188,140,255,.13)',label:'Write'}]});
  });
}

// ---- data redundancy: scheme, fault tolerance, efficiency, stripe diagram ---
// Storage Spaces expresses resiliency as columns (stripe width) x data copies
// (mirror) or parity chunks. These helpers turn that into plain answers:
// how many drives can die, and how much raw capacity a usable byte costs.
function schemeName(res,copies,red){
  if(/parity/i.test(res)) return (red>=2?'Dual':'Single')+' parity';
  if(/mirror/i.test(res)) return (copies>=3?'3-way':(copies||2)+'-way')+' mirror';
  if(/simple/i.test(res)) return 'Simple (no redundancy)';
  return res||'Unknown';
}
function faultTolerance(res,copies,red){
  if(/parity/i.test(res)) return Math.max(1,red||1);
  if(/mirror/i.test(res)) return Math.max(1,(copies||2)-1);
  return 0;
}
function efficiencyOf(res,cols,copies,red){
  if(/parity/i.test(res)){ const r=Math.max(1,red||1); return cols>r ? (cols-r)/cols : 0; }
  if(/mirror/i.test(res)) return 1/Math.max(1,copies||2);
  return 1;
}
// One stripe, drawn. Mirror => one row per copy; parity => data chunks + P/Q.
function stripeDiagram(res,cols,copies,red){
  const C=Math.max(1,cols||1);
  let rows=[];
  if(/parity/i.test(res)){
    const r=Math.max(1,red||1), dataN=Math.max(1,C-r);
    const cells=[];
    for(let i=0;i<dataN;i++) cells.push({t:'data',l:'D'+i});
    for(let i=0;i<r;i++)     cells.push({t:'parity',l:i===0?'P':'Q'});
    rows.push({lbl:'stripe',cells});
  } else if(/mirror/i.test(res)){
    const K=Math.max(2,copies||2);
    for(let k=0;k<K;k++){
      const cells=[];
      for(let i=0;i<C;i++) cells.push({t:k===0?'data':'copy',l:'D'+i});
      rows.push({lbl:k===0?'data':'copy '+k,cells});
    }
  } else {
    const cells=[];
    for(let i=0;i<C;i++) cells.push({t:'data',l:'D'+i});
    rows.push({lbl:'stripe',cells});
  }
  return `<div class="stripe" style="grid-template-columns:58px repeat(${C},minmax(34px,1fr))">`
    + rows.map(r=>`<div class="striplbl">${r.lbl}</div>`
        + r.cells.map(c=>`<div class="chunk ${c.t}">${c.l}</div>`).join('')
        + (r.cells.length<C ? Array.from({length:C-r.cells.length},()=>'<div class="chunk none">–</div>').join('') : '')
      ).join('') + `</div>`;
}
// Every space draws from the SAME pool drives, so free capacity can only be
// accounted for once, pool-wide per media type. Computing it per tier made each
// space claim all the free space as its own.
function unitsOf(v){
  const totalDrives=(v.diskNumbers||[]).length;
  return (v.tiers && v.tiers.length)
    ? v.tiers.map(t=>({label:t.name, media:t.mediaType, size:t.size,
        cap:t.driveCapacity, footprint:t.footprint, drives:t.driveCount,
        res:t.resiliency||v.resiliency, cols:t.columns||v.columns,
        copies:t.copies||v.copies, red:t.redundancy||v.redundancy}))
    : [{label:'', media:null, size:v.size, cap:0, footprint:v.footprint,
        drives:totalDrives, res:v.resiliency, cols:v.columns,
        copies:v.copies, red:v.redundancy}];
}
// Raw pool space a unit consumes: reported footprint if we have it, else derived.
function rawUsedOf(u){
  const e=efficiencyOf(u.res,u.cols,u.copies,u.red);
  return (u.footprint>0) ? u.footprint : (e>0 ? (u.size||0)/e : 0);
}
const mediaKey = m => tierOf(m) || m || 'Unknown';

function renderRedundancy(vdisks,pools,physicalDisks){
  const vds=(vdisks||[]).filter(v=>v && (v.columns||((v.tiers||[]).length)));
  if(!vds.length){ $('#redunWrap').style.display='none'; return; }
  $('#redunWrap').style.display='';

  // ---- pool capacity by media, counted ONCE across all spaces --------------
  const poolNums=new Set();
  (pools||[]).forEach(p=>(p.diskNumbers||[]).forEach(n=>poolNums.add(String(n))));
  const media={};
  const bucket=k=>media[k]||(media[k]={cap:0,used:0,drives:0});
  (physicalDisks||[]).forEach(p=>{
    const n=String(p.number);
    if(poolNums.size && !poolNums.has(n)) return;   // pool members only
    const e=bucket(mediaKey(p.mediaType));
    e.cap+=p.size||0; e.drives++;
  });
  vds.forEach(v=>unitsOf(v).forEach(u=>{ bucket(mediaKey(u.media)).used+=rawUsedOf(u); }));
  Object.keys(media).forEach(k=>{ media[k].free=Math.max(0, media[k].cap-media[k].used); });
  const mediaKeys=Object.keys(media).filter(k=>media[k].cap>0)
    .sort((a,b)=>({SCM:0,SSD:1,HDD:2}[a]??9)-({SCM:0,SSD:1,HDD:2}[b]??9));

  // Three-way split of pool capacity. Redundancy overhead and unallocated space
  // are completely different things and were previously conflated.
  let usable=0, rawUsed=0;
  vds.forEach(v=>{ usable+=v.size||0; rawUsed+=(v.footprint||0)||unitsOf(v).reduce((a,u)=>a+rawUsedOf(u),0); });
  let poolTotal=0, poolFree=0;
  (pools||[]).forEach(p=>{ poolTotal+=p.size||0; poolFree+=p.free||0; });
  const total = poolTotal>0 ? poolTotal : rawUsed;
  const overhead = Math.max(0, rawUsed-usable);
  const unalloc = poolTotal>0 ? poolFree : 0;
  const pct = v => total>0 ? (v/total*100) : 0;
  const effPct = rawUsed>0 ? (usable/rawUsed*100) : 0;

  $('#redunSummary').innerHTML = total>0
    ? `<div style="display:flex;justify-content:space-between;font-size:12px;margin-bottom:5px;flex-wrap:wrap;gap:6px">
         <span><b>${fmtBytes(usable)}</b> usable
           <span class="muted">· ${fmtBytes(overhead)} redundancy overhead${unalloc>0?(' · '+fmtBytes(unalloc)+' unallocated'):''}</span></span>
         <span class="mono muted">${fmtBytes(total)} pool · ${effPct.toFixed(0)}% resiliency efficiency</span></div>
       <div class="effbar">
         <span style="width:${pct(usable)}%;background:var(--good)"    title="usable ${fmtBytes(usable)}"></span>
         <span style="width:${pct(overhead)}%;background:var(--warn)"  title="redundancy overhead ${fmtBytes(overhead)}"></span>
         <span style="width:${pct(unalloc)}%;background:var(--border)" title="unallocated ${fmtBytes(unalloc)}"></span></div>
       <div class="status" style="margin-top:6px;font-size:11px">
         <span class="dot" style="background:var(--good)"></span>usable
         <span class="dot" style="background:var(--warn);margin-left:12px"></span>redundancy
         ${unalloc>0?'<span class="dot" style="background:var(--border);margin-left:12px"></span>unallocated':''}</div>`
    : '';

  // Shared free space, stated once per media type instead of per tier.
  if(mediaKeys.length){
    $('#redunSummary').innerHTML += `<div style="margin-top:12px">
      <div class="muted" style="font-size:11px;text-transform:uppercase;letter-spacing:.4px;margin-bottom:5px">
        Pool capacity by media <span style="text-transform:none;letter-spacing:0">· shared by every space below</span></div>
      ${mediaKeys.map(k=>{ const e=media[k]; const up=e.cap>0?(e.used/e.cap*100):0;
        return `<div style="display:flex;align-items:center;gap:10px;margin-bottom:5px;flex-wrap:wrap">
          <span style="min-width:64px">${typeTag(k)}</span>
          <span class="mono" style="font-size:12px;min-width:210px">
            <b>${fmtBytes(e.free)}</b> free of ${fmtBytes(e.cap)}</span>
          <span style="flex:1;min-width:120px">${bar(up,up>90?'var(--bad)':up>75?'var(--warn)':'var(--accent)',fmtBytes(e.used)+' used')}</span>
          <span class="muted" style="font-size:11px">${e.drives} drive${e.drives===1?'':'s'}</span>
        </div>`; }).join('')}
    </div>`;
  }

  $('#redun').innerHTML = vds.map(v=>{
    // A tiered space can mirror the SSD tier and use parity on HDD, so each
    // tier gets its own row. Untiered spaces render as a single unit.
    const totalDrives=(v.diskNumbers||[]).length;
    const units = unitsOf(v);

    return `<div style="margin-bottom:20px">
      <div style="display:flex;justify-content:space-between;flex-wrap:wrap;gap:6px;margin-bottom:4px">
        <span><b>${v.name}</b>${totalDrives?` <span class="muted">across ${totalDrives} drive${totalDrives>1?'s':''}</span>`:''}</span>
        <span class="mono muted">${v.size?fmtBytes(v.size)+' usable':''}${v.footprint?(' · '+fmtBytes(v.footprint)+' raw'):''}</span>
      </div>` + units.map(u=>{
      const ft=faultTolerance(u.res,u.copies,u.red);
      const eff01=efficiencyOf(u.res,u.cols,u.copies,u.red), eff=eff01*100;
      const minDrives=/mirror/i.test(u.res)?(u.cols||1)*Math.max(2,u.copies||2):(u.cols||1);
      const stripeBytes=(u.cols||1)*(v.interleave||0);
      // Raw CONSUMED by this tier — reported footprint if available, else derived
      // from usable/efficiency. Distinct from total drive capacity: the remainder
      // is unallocated pool space, not redundancy overhead.
      const rawUsed = rawUsedOf(u);
      const derived = !(u.footprint>0);
      // Real efficiency can trail the scheme's theoretical figure (slab rounding,
      // metadata, write-back cache), so show both when they diverge.
      const effActual = rawUsed>0 ? ((u.size||0)/rawUsed*100) : 0;
      const showBoth = rawUsed>0 && Math.abs(effActual-eff)>2;
      // Free space belongs to the POOL, not this tier — shared with every space.
      const ms = media[mediaKey(u.media)] || null;
      const have=u.drives||0;
      // fewer drives than the geometry needs => misconfigured or degraded
      const short=have>0 && have<minDrives;
      const driveTxt = have
        ? `<span style="${short?'color:var(--bad);font-weight:600':''}">${have} drive${have>1?'s':''}</span>`
          +`<span class="muted"> (min ${minDrives})</span>${short?' <span class="ftol none">below minimum</span>':''}`
        : `<span class="muted">min ${minDrives} drives</span>`;
      return `<div style="margin:8px 0 2px;padding:9px 11px;background:var(--panel2);border-radius:8px">
        <div style="display:flex;align-items:center;gap:9px;flex-wrap:wrap;margin-bottom:6px">
          ${u.media?typeTag(u.media):''}<b style="font-size:13px">${u.label?u.label+' · ':''}${schemeName(u.res,u.copies,u.red)}</b>
          <span class="ftol ${ft>0?'ok':'none'}">${ft>0?('survives '+ft+' drive failure'+(ft>1?'s':'')):'no redundancy'}</span>
        </div>
        <div class="muted" style="font-size:12px;margin-bottom:2px">
          <b class="mono" style="color:var(--text)">${u.size?fmtBytes(u.size):'–'}</b> usable
          ${rawUsed?('· '+(derived?'~':'')+fmtBytes(rawUsed)+' raw used ('
             +(showBoth?(effActual.toFixed(0)+'% actual, '+eff.toFixed(0)+'% scheme'):(eff.toFixed(0)+'% efficient'))+')')
             :('· '+eff.toFixed(0)+'% efficient')}
          · ${driveTxt}
          · ${u.cols||'?'} column${(u.cols||1)>1?'s':''}${u.copies>1?(' × '+u.copies+' copies'):''}${stripeBytes?(' · '+fmtBytes(stripeBytes)+' per stripe'):''}
        </div>
        ${(ms&&ms.free>0)?`<div class="muted" style="font-size:11px;margin-bottom:4px">
          <b style="color:var(--warn)">${fmtBytes(ms.free)}</b> free on ${mediaKey(u.media)} — <i>shared pool space</i>,
          worth ~${fmtBytes(ms.free*eff01)} more usable at this resiliency
        </div>`:''}
        ${stripeDiagram(u.res,u.cols,u.copies,u.red)}
        <div class="muted" style="font-size:11px;margin-top:5px">${
          /parity/i.test(u.res)
            ? `Each stripe splits data across ${Math.max(1,(u.cols||1)-Math.max(1,u.red||1))} columns and computes ${Math.max(1,u.red||1)} parity chunk${(u.red||1)>1?'s':''}; parity rotates between drives on every stripe.`
            : /mirror/i.test(u.res)
              ? `Each ${fmtBytes(v.interleave||0)} chunk is written ${Math.max(2,u.copies||2)}× to different drives; striped across ${u.cols||1} column${(u.cols||1)>1?'s':''} for throughput.`
              : `Data is striped across ${u.cols||1} column${(u.cols||1)>1?'s':''} with no redundancy — any drive loss destroys the space.`}</div>
      </div>`;
    }).join('') + `</div>`;
  }).join('');
}

// ---- data layout: column/copy -> drive map ---------------------------------
const tierColor = m => /scm/i.test(m)?cssVar('--good'):/ssd/i.test(m)?cssVar('--read'):/hdd/i.test(m)?cssVar('--write'):cssVar('--muted');
function renderLayout(layout){
  if(!layout||!layout.length){ $('#layoutWrap').style.display='none'; return; }
  $('#layoutWrap').style.display='';
  $('#layout').innerHTML=layout.map(v=>{
    let body='';
    if(v.exact && v.cells && v.cells.length){
      // Split by media type: on a tiered space each tier has its own column set.
      const byMedia={};
      v.cells.forEach(c=>{ (byMedia[c.mediaType]=byMedia[c.mediaType]||[]).push(c); });
      const order={SCM:0,SSD:1,HDD:2};
      body=Object.keys(byMedia).sort((a,b)=>(order[a]??9)-(order[b]??9)).map(mt=>{
        const cs=byMedia[mt];
        const cols=Math.max(...cs.map(c=>c.column))+1;
        const copies=Math.max(...cs.map(c=>c.copy))+1;
        const bytes=cs.reduce((a,c)=>a+c.bytes,0);
        const drives=new Set(cs.map(c=>c.diskNumber)).size;
        let g=`<div class="layhdr" style="text-align:left"></div>`
          +Array.from({length:cols},(_,i)=>`<div class="layhdr">col ${i}</div>`).join('');
        for(let cp=0;cp<copies;cp++){
          g+=`<div class="layrowlbl">${copies>1?('copy '+cp):'data'}</div>`;
          for(let cl=0;cl<cols;cl++){
            const c=cs.find(z=>z.copy===cp&&z.column===cl);
            g+= c ? `<div class="laycell" style="border-left-color:${tierColor(c.mediaType)}" title="${c.diskName} — ${fmtBytes(c.bytes)} (${c.slabs} slabs)"><b>#${c.diskNumber??'?'}</b>${fmtBytes(c.bytes)}</div>`
                  : `<div class="laycell muted">–</div>`;
          }
        }
        return `<div style="margin:10px 0 16px">
          <div style="font-size:12px;margin-bottom:6px">${typeTag(mt)} <b>${mt} tier</b>
            <span class="muted">${cols} column${cols>1?'s':''} × ${copies} cop${copies>1?'ies':'y'}
            · ${drives} drive${drives>1?'s':''} · ${fmtBytes(bytes)}</span></div>
          <div class="laygrid" style="grid-template-columns:64px repeat(${cols},minmax(58px,1fr))">${g}</div></div>`;
      }).join('');
    } else if(v.tiers && v.tiers.length){
      // Fast path: tier membership + layout parameters (no per-slab scan).
      const cls=m=>/ssd/i.test(m)?'ssd':/hdd/i.test(m)?'hdd':/scm/i.test(m)?'scm':'';
      body=v.tiers.map(t=>{
        const stripe=(t.columns&&v.interleave)?fmtBytes(t.columns*v.interleave):null;
        const chips=(t.drives||[]).map(dr=>
          `<span class="tag ${cls(dr.mediaType)}" title="${dr.name}" style="padding:3px 9px">#${dr.number??'?'} · ${fmtBytes(dr.size)}</span>`).join('');
        return `<div style="margin:10px 0 15px">
          <div style="font-size:12px;margin-bottom:6px">${typeTag(t.mediaType)} <b>${t.name}</b>
            <span class="muted">${t.columns?(t.columns+' column'+(t.columns>1?'s':'')):''}${t.copies>1?(' × '+t.copies+' copies'):''}
            · ${(t.drives||[]).length} drive${(t.drives||[]).length!==1?'s':''}${t.size?(' · '+fmtBytes(t.size)):''}${stripe?(' · '+stripe+' stripe'):''}</span></div>
          <div style="display:flex;flex-wrap:wrap;gap:6px">${chips||'<span class="muted">no member drives resolved</span>'}</div></div>`;
      }).join('')
      +`<div class="muted" style="font-size:11px;margin-top:2px">Tier membership and layout parameters.${
        v.exactTried?' Exact per-slab placement timed out on this pool.':' Run with <b>-ExactLayout</b> for exact column→drive placement (slow on large pools).'}</div>`;
    } else { body='<span class="muted">No layout data available.</span>'; }
    return `<div style="margin-bottom:22px">
      <div style="display:flex;justify-content:space-between;flex-wrap:wrap;gap:6px">
        <span><b>${v.name}</b> <span class="muted">${v.resiliency||''}</span></span>
        <span class="mono muted">${v.columns?(v.columns+' columns'):''}${v.copies>1?(' · '+v.copies+' copies'):''}${v.interleave?(' · '+fmtBytes(v.interleave)+' interleave'):''}${v.extents?(' · '+num(v.extents)+' slabs'):''}</span></div>
      ${v.partial?'<div class="muted" style="font-size:11px;margin-top:4px">⚠ extent scan capped — sizes below are a partial sample; column→drive mapping is still accurate.</div>':''}
      ${body}</div>`;
  }).join('');
}

// ---- pool overview (Capacity tab) ------------------------------------------
// The pool is the authoritative source for free space: allocated vs total comes
// straight from Storage Spaces rather than being derived from drive capacity.
function renderPools(pools, vdisks, diag, ready, primordial, phys){
  const ps=(pools||[]);
  const wrap=$('#poolOverviewWrap'), kpi=$('#poolKpis');

  // Reconcile the primordial "unclaimed" figure against actual drives: any disk
  // Storage Spaces can see but that no pool claims. Usually the boot/RAID volume.
  const pooled=new Set();
  ps.forEach(p=>(p.diskNumbers||[]).forEach(n=>pooled.add(String(n))));
  const unpooled=(phys||[]).filter(p=>!pooled.has(String(p.number)));
  const unpooledBytes=unpooled.reduce((a,p)=>a+(p.size||0),0);
  const recon = unpooled.length ? `
      <div style="margin-top:7px">
        <b style="color:var(--text)">${unpooled.length} drive${unpooled.length>1?'s':''} not in any pool</b>
        · ${fmtBytes(unpooledBytes)} total —
        ${unpooled.map(p=>`<span class="tag" style="margin-right:5px">#${p.number} ${p.name} · ${fmtBytes(p.size)}${p.isSystem?' · system':''}</span>`).join('')}
      </div>` : '';

  // Primordial isn't a usable pool — it's every drive Storage Spaces can see —
  // so it's reported separately rather than mixed into the pool totals.
  const prim = primordial && primordial.size>0 ? `
    <div class="muted" style="border-top:1px solid var(--border);padding-top:10px;margin-top:6px;font-size:12px">
      <b>Primordial</b> · all media Storage Spaces can see ·
      <b class="mono" style="color:var(--text)">${fmtBytes(primordial.size)}</b> total ·
      ${fmtBytes(primordial.allocated)} claimed by pools ·
      <b style="color:${primordial.unclaimed>0?'var(--good)':'var(--muted)'}">${fmtBytes(primordial.unclaimed)}</b> unclaimed
      ${recon}
    </div>` : '';
  if(!ps.length){
    wrap.style.display='';
    kpi.innerHTML='';
    // "No pool" is a CLAIM — only make it once the collector has actually
    // reported. Before that it's simply not loaded yet.
    $('#poolOverview').innerHTML = ready
      ? `<div class="muted" style="font-size:12px">
           <b style="color:var(--warn)">No storage pool available.</b><br>
           Virtual disks and drives are read directly, so everything else on this page is accurate —
           only the pool-level allocated/unallocated figures are missing.
           <span style="display:block;margin-top:6px">See the dashboard console window for details.</span>
         </div>` + prim
      : `<div class="muted" style="font-size:12px">Loading pool data…</div>`;
    return;
  }
  wrap.style.display='';

  let total=0, alloc=0, free=0;
  ps.forEach(p=>{ total+=p.size||0; alloc+=p.allocated||0; free+=(p.free!=null?p.free:Math.max(0,(p.size||0)-(p.allocated||0))); });
  const vdTotal=(vdisks||[]).reduce((a,v)=>a+(v.size||0),0);
  const pct=total>0?(alloc/total*100):0;

  kpi.innerHTML=`
    <div class="card kpi"><h2>Pool Size</h2><div><span class="v mono">${fmtBytes(total)}</span></div><div class="sub">${ps.length} pool${ps.length>1?'s':''}${diag&&diag.poolVia?(' · via '+diag.poolVia):''}</div></div>
    <div class="card kpi"><h2>Allocated</h2><div><span class="v mono">${fmtBytes(alloc)}</span></div><div class="sub">${pct.toFixed(0)}% of pool committed</div></div>
    <div class="card kpi"><h2>Unallocated</h2><div><span class="v mono" style="color:${free>0?'var(--good)':'var(--warn)'}">${fmtBytes(free)}</span></div><div class="sub">available to extend or create</div></div>
    <div class="card kpi"><h2>Usable Provisioned</h2><div><span class="v mono">${fmtBytes(vdTotal)}</span></div><div class="sub">across ${(vdisks||[]).length} virtual disk${(vdisks||[]).length===1?'':'s'}</div></div>`;

  $('#poolOverview').innerHTML=ps.map(p=>{
    const pf=(p.free!=null)?p.free:Math.max(0,(p.size||0)-(p.allocated||0));
    const up=p.size>0?(p.allocated/p.size*100):0;
    const mine=(vdisks||[]).filter(v=>(v.diskNumbers||[]).some(n=>(p.diskNumbers||[]).includes(n)));
    return `<div style="margin-bottom:16px">
      <div style="display:flex;justify-content:space-between;flex-wrap:wrap;gap:6px;margin-bottom:5px">
        <span><b>${p.name}</b> <span class="muted">${(p.diskNumbers||[]).length} drives · ${healthDot(p.health)}</span></span>
        <span class="mono muted">${fmtBytes(p.allocated)} allocated of ${fmtBytes(p.size)}</span></div>
      <div class="effbar">
        <span style="width:${up}%;background:${up>90?'var(--bad)':up>75?'var(--warn)':'var(--accent)'}" title="allocated ${fmtBytes(p.allocated)}"></span>
        <span style="width:${100-up}%;background:var(--border)" title="unallocated ${fmtBytes(pf)}"></span></div>
      <div class="muted" style="font-size:12px;margin-top:7px">
        <b style="color:var(--good)">${fmtBytes(pf)}</b> unallocated
        ${mine.length?(' · hosts '+mine.map(v=>v.name).join(', ')):''}</div>
    </div>`;
  }).join('') + prim;
}

// ---- drive rollup (Drives tab). Split out so the °C/°F toggle can re-render
// it instantly from the cached topology instead of waiting 30s for a refresh.
let lastTopoData=null;
function applyTopoDerived(d){
  const pd=d.physicalDisks||[];
  const healthy=pd.filter(p=>isOkHealth(p.health)).length;
  const bad=pd.filter(p=>p.health && !isOkHealth(p.health));
  const temps=pd.filter(p=>p.tempC!=null&&p.tempC>0);
  const wears=pd.filter(p=>p.wear!=null);
  const byMediaCount={};
  pd.forEach(p=>{ const k=tierOf(p.mediaType)||p.mediaType||'other'; byMediaCount[k]=(byMediaCount[k]||0)+1; });
  $('#kDrives').textContent=pd.length||'–';
  $('#kDrivesSub').textContent=Object.keys(byMediaCount).map(k=>byMediaCount[k]+' '+k).join(' · ');
  $('#kHealth').innerHTML = pd.length
    ? (bad.length? `<span style="color:var(--bad)">${bad.length} not healthy</span>` : `<span style="color:var(--good)">all healthy</span>`)
    : '–';
  $('#kHealthSub').textContent = bad.length? bad.map(b=>'#'+b.number+' '+b.health).slice(0,3).join(', ')
                                           : healthy+' drives OK';
  const tu=$('#kTempUnit'); if(tu) tu.textContent=tempUnit();
  // SMART sweeps are slow; report progress rather than an ambiguous dash.
  const wp=d.wearProgress;
  const sweeping = wp && wp.total>0 && wp.done<wp.total;
  const sweepMsg = sweeping ? `reading SMART ${wp.done}/${wp.total}…` : null;
  if(temps.length){
    const hot=temps.reduce((a,b)=>b.tempC>a.tempC?b:a);
    const med=temps.map(t=>t.tempC).sort((a,b)=>a-b)[Math.floor(temps.length/2)];
    $('#kTemp').textContent=Math.round(tempVal(hot.tempC));
    $('#kTempSub').textContent = sweepMsg || ('#'+hot.number+' · median '+tempStr(med));
  } else { $('#kTemp').textContent = sweeping?'…':'–';
           $('#kTempSub').textContent = sweepMsg || 'no SMART temps'; }
  if(wears.length){ const mw=wears.reduce((a,b)=>b.wear>a.wear?b:a);
    $('#kWear').textContent=Math.round(mw.wear);
    $('#kWearSub').textContent = sweepMsg || ('#'+mw.number+' · '+wears.length+' reporting');
  } else { $('#kWear').textContent = sweeping?'…':'–';
           $('#kWearSub').textContent = sweepMsg || 'no SMART wear data'; }
  $('#nbDrives').textContent=pd.length||'';
  $('#nbCap').textContent=(d.pools||[]).length||'';

  // ---- nav health dots ----
  // Green when verified healthy — silence would be indistinguishable from
  // "not loaded" or "feature broken", which is no reassurance at all.
  const dw=worstOf(pd.map(p=>p.health));
  setNavHealth('#ndDrives', pd.length?(dw.level||'ok'):null,
    !pd.length ? ''
      : dw.level ? `${dw.n} drive${dw.n>1?'s':''} not healthy: `
                   + pd.filter(p=>!isOkHealth(p.health)).map(p=>'#'+p.number+' '+p.health).slice(0,5).join(', ')
                 : `all ${pd.length} drives healthy`);

  const cap=[...(d.pools||[]),...(d.virtualDisks||[])];
  const cw=worstOf(cap.map(x=>x.health));
  setNavHealth('#ndCap', cap.length?(cw.level||'ok'):null,
    !cap.length ? ''
      : cw.level ? `${cw.n} pool/virtual disk${cw.n>1?'s':''} not healthy`
                 : `${(d.pools||[]).length} pool / ${(d.virtualDisks||[]).length} virtual disks healthy`);
}

// ---- system / Storage Spaces internals (1s) --------------------------------
const histCpu=[];
let sysData=null;
// System counters have their own cadence and a much longer window — tier
// optimisation happens in bursts over minutes. Points are derived so the window
// stays ~30 min whatever -SystemMs is set to.
const SYSH=Math.max(600, Math.round(CFG.sysHistoryMs/CFG.systemMs));
function pushN(arr,v,max){ arr.push(v); if(arr.length>max) arr.shift(); }

// ---- tier optimisation: per-tier history + graphs --------------------------
const tmHist={}; const tmEls={}; let tmKey=null, lastSysAt=0;
function tmH(k){ return tmHist[k]||(tmHist[k]={read:[],write:[],total:[],ops:[],lat:[],inflight:[],moved:0}); }

function renderTierMove(tiers){
  const list=(tiers||[]).filter(t=>t&&t.instance!==undefined);
  if(!list.length){ $('#tierMoveWrap').style.display='none'; return; }
  $('#tierMoveWrap').style.display='';

  const now=Date.now();
  const dt = lastSysAt ? Math.min(10,(now-lastSysAt)/1000) : 0;   // clamp after a pause
  lastSysAt=now;

  const key=list.map(t=>t.instance).join('|');
  if(key!==tmKey){
    tmKey=key;
    for(const k in tmEls) delete tmEls[k];
    $('#tierMove').innerHTML=list.map(t=>`<div class="tmrow" data-tm="${t.instance}" style="margin-bottom:20px">
      <div style="display:flex;justify-content:space-between;flex-wrap:wrap;gap:6px;margin-bottom:5px">
        <span><b>${t.instance||'tier'}</b> <span class="muted tm-sub"></span></span>
        <span class="mono muted tm-stats"></span></div>
      <div class="cellspark"><canvas class="mini tm-spark" style="height:56px"></canvas><span class="mono tm-now"></span></div>
      <div class="muted tm-extra" style="font-size:11px;margin-top:7px"></div>
    </div>`).join('');
    $('#tierMove').querySelectorAll('.tmrow').forEach(el=>{
      tmEls[el.dataset.tm]={sub:el.querySelector('.tm-sub'),stats:el.querySelector('.tm-stats'),
        spark:el.querySelector('.tm-spark'),now:el.querySelector('.tm-now'),extra:el.querySelector('.tm-extra')};
    });
  }

  const rc=cssVar('--read'), wc=cssVar('--write');
  let grandMoved=0, anyActive=false;
  list.forEach(t=>{
    const e=tmEls[String(t.instance)]; if(!e) return;
    const h=tmH(t.instance);
    const rB=t.readBps||0, wB=t.writeBps||0, tB=t.bps||(rB+wB);
    pushN(h.read,rB,SYSH); pushN(h.write,wB,SYSH); pushN(h.total,tB,SYSH);
    pushN(h.ops,t.ops||0,SYSH); pushN(h.lat,t.latency||0,SYSH); pushN(h.inflight,t.inflight||0,SYSH);
    h.moved += tB*dt;                       // integrate throughput -> bytes moved
    grandMoved+=h.moved;
    if(tB>0||(t.ops||0)>0) anyActive=true;

    if(visible($('#tierMove'))){
      drawMini(e.spark,[{data:h.read,color:rc,fill:'rgba(74,163,255,.14)'},
                        {data:h.write,color:wc,fill:'rgba(188,140,255,.14)'}],null,56,SYSH);
    }
    // Direction matters: a READ on a tier means data is leaving it (being
    // promoted/demoted elsewhere); a WRITE means data is landing on it.
    setSpec(e.spark,{title:(t.instance||'tier')+' — Tier movement', unit:'MB/s', scale:MBs,
      maxPoints:SYSH, sampleMs:CFG.systemMs, series:[
        {data:h.read,color:rc,fill:'rgba(74,163,255,.14)',label:'Read off this tier'},
        {data:h.write,color:wc,fill:'rgba(188,140,255,.14)',label:'Written to this tier'}]});

    const idle = tB<=0 && (t.ops||0)<=0;
    e.sub.textContent = idle ? 'idle' : 'moving data';
    e.now.textContent = mbps(tB).toFixed(1);
    e.now.style.color = idle ? 'var(--muted)' : 'var(--accent)';
    e.stats.textContent = mbps(rB).toFixed(1)+' ▼ read off / '+mbps(wB).toFixed(1)+' ▲ written to · '
      + num(t.ops||0)+' transfers/s'+(t.inflight?(' · '+num(t.inflight)+' in flight'):'');
    e.stats.title='Read off this tier '+mbps(rB).toFixed(1)+' MB/s · written to this tier '
      +mbps(wB).toFixed(1)+' MB/s';
    e.extra.innerHTML =
      `<b style="color:var(--text)">${fmtBytes(h.moved)}</b> moved since load`
      + ` · peak ${mbps(maxOf(h.total)).toFixed(1)} MB/s`
      + (t.avgXfer?` · avg transfer ${fmtBytes(t.avgXfer,0)}`:'')
      + (t.latency?` · latency ${Number(t.latency).toFixed(1)} ms`:'')
      + (t.readLat||t.writeLat?` <span class="muted">(r ${Number(t.readLat||0).toFixed(1)} / w ${Number(t.writeLat||0).toFixed(1)} ms)</span>`:'');
  });
  $('#tmSummary').innerHTML = grandMoved>0
    ? `<b class="mono">${fmtBytes(grandMoved)}</b> moved between tiers since this page loaded
       <span class="muted">· ${anyActive?'currently active':'idle right now'} · 30 min window, 1s resolution</span>`
    : `<span class="muted">No tier movement observed yet. Storage Spaces optimises tiers on a schedule
       (Task Scheduler → Microsoft → Windows → Storage Tiers Management) or when you run Optimize-Volume -TierOptimize.</span>`;
}
function renderSystem(s){
  if(!s) return;
  sysData=s;
  if(typeof s.cpu==='number'){
    pushN(histCpu,s.cpu,SYSH);            // 1s cadence -> the long window
    const c=avgLast(histCpu,5);
    $('#kCpu').textContent=c.toFixed(0);
    drawMini($('#kCpuSpark'),[{data:histCpu,color:colorFor(c),fill:busyFill(c)}],100,28,SYSH);
    const sp=$('#kCpuSpark')._spec;
    if(sp){ sp.series[0].color=colorFor(c); sp.series[0].fill=busyFill(c); }
  }
  if(typeof s.splitIo==='number') $('#kSplit').textContent=num(s.splitIo);

  // Windows file cache
  const set=(id,v)=>{ const el=$(id); if(el) el.textContent = (v==null?'–':fmtBytes(v)); };
  set('#kMemCache',   s.memCache);
  set('#kMemStandby', s.memStandby);
  set('#kMemMod',     s.memModified);
  $('#kMemAvail').textContent = (s.memAvailMB==null)?'–':fmtBytes(s.memAvailMB*1048576);

  // --- Storage Spaces write-back cache (the real cache numbers) ---
  const wc=(s.writeCache||[]).filter(w=>w && (w.size>0||w.used>0));
  if(wc.length){
    $('#wcBody').innerHTML=wc.map(w=>{
      const usedPct = w.size>0 ? (w.used/w.size*100) : (w.usedPct||0);
      const hitW=w.writeHitPct||0, byW=w.writeBypassPct||0;
      const hitR=w.readHitPct||0,  byR=w.readBypassPct||0;
      return `<div style="margin-bottom:16px">
        <div style="display:flex;justify-content:space-between;flex-wrap:wrap;gap:6px;margin-bottom:5px">
          <span><b>${w.instance||'cache'}</b> <span class="muted">write-back cache</span></span>
          <span class="mono muted">${fmtBytes(w.used||0)} used of ${fmtBytes(w.size||0)}${w.destages?(' · '+num(w.destages)+' destages in flight'):''}</span></div>
        ${bar(usedPct, usedPct>90?'var(--bad)':usedPct>75?'var(--warn)':'var(--accent)', usedPct.toFixed(0)+'% full')}
        <div class="muted" style="font-size:12px;margin-top:7px">
          <b class="mono" style="color:var(--text)">${fmtBytes(w.data||0)}</b> data ·
          <b class="mono" style="color:var(--text)">${fmtBytes(w.reclaimable||0)}</b> reclaimable</div>
        <div style="display:flex;gap:18px;flex-wrap:wrap;margin-top:8px;font-size:12px">
          <span><span class="dot" style="background:var(--write)"></span>writes cached <b>${hitW.toFixed(0)}%</b>
            <span class="muted">· bypassed ${byW.toFixed(0)}%</span></span>
          <span><span class="dot" style="background:var(--read)"></span>reads cached <b>${hitR.toFixed(0)}%</b>
            <span class="muted">· bypassed ${byR.toFixed(0)}%</span></span>
        </div></div>`;
    }).join('')
    + `<div class="muted" style="font-size:11px;border-top:1px solid var(--border);padding-top:8px">
        The write-back cache absorbs <b>small random writes</b>; large sequential writes bypass it by
        design, so a high write-bypass % on streaming workloads is normal. Read hits only occur while
        data is still resident before destaging, so a low read-cache % on a cache this size relative
        to the volume is expected — not a fault.</div>`;
    const tot=wc.reduce((a,w)=>a+(w.size||0),0), used=wc.reduce((a,w)=>a+(w.used||0),0);
    if(tot>0){ $('#kCache').textContent=fmtBytes(used);
               $('#kCacheSub').textContent=(used/tot*100).toFixed(0)+'% of '+fmtBytes(tot); }
  } else {
    $('#wcBody').innerHTML='<span class="muted">No write-back cache instances reported. '
      +'Storage Spaces only exposes these counters when a vdisk has a write-back cache configured.</span>';
  }

  renderTierMove(s.tier);

  // --- repair / regeneration health ---
  const vd=(s.vdisk||[]).filter(v=>v && (v.total>0||v.needRegen>0||v.stale>0||v.missing>0));
  // Degraded data is a resiliency problem you shouldn't have to go looking for.
  const miss=vd.reduce((a,v)=>a+(v.missing||0),0);
  const regen=vd.reduce((a,v)=>a+(v.needRegen||0),0)+vd.reduce((a,v)=>a+(v.stale||0),0);
  setNavHealth('#ndRes', vd.length?(miss>0?'bad':(regen>0?'warn':'ok')):null,
    !vd.length ? ''
      : miss>0  ? fmtBytes(miss)+' missing — data is not fully protected'
      : regen>0 ? fmtBytes(regen)+' needs regeneration'
                : 'all data fully protected');
  if(vd.length){
    $('#repairWrap').style.display='';
    $('#repair').innerHTML=vd.map(v=>{
      const bad=(v.needRegen||0)+(v.stale||0)+(v.missing||0);
      const okPct=v.total>0?Math.max(0,100-(bad/v.total*100)):100;
      const chip=(lbl,val,cls)=>`<span class="ftol ${cls}" style="margin-right:8px">${lbl} ${fmtBytes(val||0)}</span>`;
      return `<div style="margin-bottom:14px">
        <div style="display:flex;justify-content:space-between;flex-wrap:wrap;gap:6px;margin-bottom:5px">
          <span><b>${v.instance||'vdisk'}</b></span>
          <span class="mono muted">${fmtBytes(v.active||0)} active of ${fmtBytes(v.total||0)}</span></div>
        ${bar(okPct, bad>0?'var(--warn)':'var(--good)', bad>0?'needs attention':'fully healthy')}
        <div style="margin-top:8px;font-size:12px">
          ${chip('needs regeneration', v.needRegen, (v.needRegen>0)?'none':'ok')}
          ${chip('stale', v.stale, (v.stale>0)?'none':'ok')}
          ${chip('missing', v.missing, (v.missing>0)?'none':'ok')}
          ${v.scrubBps>0?`<span class="muted">· scrubbing ${mbps(v.scrubBps).toFixed(1)} MB/s</span>`:''}
        </div></div>`;
    }).join('');
  } else { $('#repairWrap').style.display='none'; }
}
async function pollSystem(){
  try{ const r=await fetch('/api/system'); renderSystem(await r.json()); }catch(e){}
}

async function pollPerf(){
  try{
    const r=await fetch('/api/perf'); const d=await r.json();
    $('#conn').innerHTML='<span class="dot" style="background:var(--good)"></span>live';
    $('#clock').textContent=new Date(d.timestamp).toLocaleTimeString();
    $('#feeds').textContent=(d.mapped===false?'mapping drives… · ':'')
      +'topology '+(lastTopoAt?Math.round((Date.now()-lastTopoAt)/1000)+'s':'—')
      +' · '+poolState+' · layout '+layoutState+' · wear '+wearState;
    if(topoDiag) $('#feeds').title='storage scan: disk map '+topoDiag.mapMs+'ms, full pass '
      +topoDiag.passMs+'ms across '+topoDiag.drives+' drives · click to refresh';

    // Everything below respects the active pool/space filter. Totals are summed
    // client-side from the filtered POOL MEDIA so the KPIs and graphs scope too.
    const disks=filterDisks(d.disks);
    const pm=disks.filter(isPoolMedia);
    // Don't seed the graphs with zeros before the disk map exists — that drew a
    // flat line that looked like "no I/O" rather than "not classified yet".
    const waiting = (d.mapped===false) && d.disks.length>0;
    if(!waiting){
      push(histR,pm.reduce((a,x)=>a+x.readBps,0));
      push(histW,pm.reduce((a,x)=>a+x.writeBps,0));
      push(histI,pm.reduce((a,x)=>a+x.reads+x.writes,0));
    }

    // these also append to the per-disk / per-tier ring buffers
    renderDisks(disks);
    renderTierActivity(disks);
    renderSpaces(disks);

    // KPI tiles show smoothed values (raw ones are unreadable at ~100ms).
    if(waiting){
      ['#kRead','#kWrite','#kIops','#kIoSize','#kMix'].forEach(id=>{const e=$(id); if(e) e.textContent='–';});
      ['#kReadSub','#kWriteSub','#kIopsSub'].forEach(id=>{const e=$(id); if(e) e.textContent='mapping drives…';});
    } else {
      $('#kRead').textContent=mbps(avgLast(histR)).toFixed(1);
      $('#kWrite').textContent=mbps(avgLast(histW)).toFixed(1);
      $('#kIops').textContent=num(avgLast(histI));
      $('#kReadSub').textContent='peak '+mbps(maxOf(histR)).toFixed(1)+' MB/s';
      $('#kWriteSub').textContent='peak '+mbps(maxOf(histW)).toFixed(1)+' MB/s';
      $('#kIopsSub').textContent='peak '+num(maxOf(histI));
    }

    // header sparklines
    drawMini($('#kReadSpark'), [{data:histR,color:cssVar('--read'), fill:'rgba(74,163,255,.16)'}],null,28);
    drawMini($('#kWriteSpark'),[{data:histW,color:cssVar('--write'),fill:'rgba(188,140,255,.16)'}],null,28);
    drawMini($('#kIopsSpark'), [{data:histI,color:cssVar('--accent'),fill:'rgba(74,163,255,.16)'}],null,28);

    // Derived workload character: average I/O size distinguishes sequential
    // (large) from random (small) traffic, and the read/write mix drives cache
    // and resiliency choices.
    const rIops=pm.reduce((a,x)=>a+x.reads,0), wIops=pm.reduce((a,x)=>a+x.writes,0);
    const rBps=pm.reduce((a,x)=>a+x.readBps,0), wBps=pm.reduce((a,x)=>a+x.writeBps,0);
    const rSz=rIops>0?rBps/rIops:0, wSz=wIops>0?wBps/wIops:0;
    const tot=rIops+wIops;
    // Signed balance: +100 = all reads, -100 = all writes, 0 = even split.
    push(histRSz,rSz); push(histWSz,wSz);
    push(histMix, tot>0 ? ((rIops-wIops)/tot*100) : 0);
    // Idle reads as 0 / 0, never as a null dash: flipping between a value and
    // "–" every time IOPS touch zero is just flicker.
    $('#kIoSize').textContent = fmtBytes(rSz,0)+' / '+fmtBytes(wSz,0);
    $('#kMix').textContent = tot>0 ? (Math.round(rIops/tot*100)+' / '+Math.round(wIops/tot*100)) : '0 / 0';
    $('#kMixSub').textContent = 'read / write % of '+num(tot)+' IOPS';
    drawMini($('#kIoSizeSpark'),[{data:histRSz,color:cssVar('--read')},
                                 {data:histWSz,color:cssVar('--write')}],null,28);
    drawMini($('#kMixSpark'),[{data:histMix,color:cssVar('--muted'),
      fill:'rgba(74,163,255,.30)', fillNeg:'rgba(188,140,255,.30)'}],100,28,MAXH,true);
    $('#nbJobs').textContent = (d.jobs&&d.jobs.length)?d.jobs.length:'';
    drawSpark();
    drawModal();   // keep an open zoom popup live

    // jobs
    if(d.jobs && d.jobs.length){
      $('#jobs').className='';
      $('#jobs').innerHTML=d.jobs.map(j=>`<div style="margin-bottom:10px">
        <div style="display:flex;justify-content:space-between;font-size:12px;margin-bottom:3px">
          <span><b>${j.name}</b> <span class="muted">${j.description||''} · ${j.state}</span></span>
          <span class="mono">${j.percent.toFixed(0)}%</span></div>
        ${bar(j.percent,'var(--accent)',fmtBytes(j.bytesProcessed)+' / '+fmtBytes(j.bytesTotal))}</div>`).join('');
    } else { $('#jobs').className='jobsempty'; $('#jobs').textContent='No active storage jobs.'; }
  }catch(e){
    $('#conn').innerHTML='<span class="dot" style="background:var(--bad)"></span>disconnected';
  }
}

async function pollTopology(){
  try{
    const r=await fetch('/api/topology'); const d=await r.json();
    lastTopoAt=Date.now();
    topoReady = !(d.warming===true || !d.timestamp);
    if(d.diag) topoDiag=d.diag;
    // Report virtual disks, not pools: Get-StoragePool returning 0 is common and
    // says nothing useful, whereas the vdisk count is always meaningful.
    const nv=(d.virtualDisks||[]).length;
    poolState=(d.warming===true||!d.timestamp)?'loading':(nv+' vdisk'+(nv===1?'':'s'));
    layoutState=(d.layout&&d.layout.length)?(d.layout.length+' vdisk'+(d.layout.length>1?'s':'')):'pending';
    wearState=((d.physicalDisks||[]).some(p=>p.wear!=null||p.tempC!=null))?'ok':'n/a';

    // membership sets for click-to-filter (refreshed with topology)
    const fs={pool:{},space:{}};
    (d.pools||[]).forEach(p=>{ fs.pool[p.name]=new Set((p.diskNumbers||[]).map(String)); });
    (d.virtualDisks||[]).forEach(v=>{
      const s=new Set((v.diskNumbers||[]).map(String));
      if(v.number!=null && v.number!=='') s.add(String(v.number)); // include the space's own row
      fs.space[v.name]=s;
    });
    filterSets=fs;

    // header pool health + wbc kpi
    // (The old header pool-health chip lived here. Get-StoragePool can return
    // nothing even on a healthy system with working virtual disks, which made
    // the chip actively misleading — per-object health is shown in context.)
    const wbc=d.virtualDisks.reduce((a,v)=>a+(v.writeCacheSize||0),0);
    $('#kCache').textContent=wbc>0?fmtBytes(wbc):'none';

    // pools + vdisks
    const pr=d.pools.map(p=>`<tr data-ft="pool" data-fk="${p.name}" title="Click to filter to this pool">
      <td><b>${p.name}</b><div class="muted" style="font-size:11px">pool · ${(p.diskNumbers||[]).length} drives</div></td>
      <td>${bar(p.pctUsed,p.pctUsed>90?'var(--bad)':p.pctUsed>75?'var(--warn)':'var(--accent)',p.pctUsed+'%')}</td>
      <td class="right mono">${fmtBytes(p.size)}</td><td>${healthDot(p.health)}</td></tr>`);
    const vr=d.virtualDisks.map(v=>{ const used=v.size?Math.min(100,v.allocated/v.size*100):0;
      return `<tr data-ft="space" data-fk="${v.name}" title="Click to filter to this space">
      <td><b>${v.name}</b><div class="muted" style="font-size:11px">${v.resiliency||''} · ${v.provisioning||''}${v.writeCacheSize>0?' · WBC '+fmtBytes(v.writeCacheSize):''}</div></td>
      <td>${bar(used,'var(--muted)',fmtBytes(v.allocated)+' used')}</td>
      <td class="right mono">${fmtBytes(v.size)}</td><td>${healthDot(v.health)}</td></tr>`; });
    $('#poolTbl tbody').innerHTML=(pr.concat(vr)).join('')||'<tr><td colspan="4" class="muted">No pools found.</td></tr>';

    // volumes
    $('#volTbl tbody').innerHTML=d.volumes.map(v=>`<tr>
      <td><b>${v.drive}</b> <span class="muted">${v.label||''}</span></td>
      <td>${bar(v.pctUsed,v.pctUsed>90?'var(--bad)':v.pctUsed>75?'var(--warn)':'var(--good)',v.pctUsed+'%')}</td>
      <td class="right mono">${fmtBytes(v.free)}</td>
      <td class="right mono">${fmtBytes(v.size)}</td></tr>`).join('')||'<tr><td colspan="4" class="muted">No fixed volumes.</td></tr>';

    renderPools(d.pools, d.virtualDisks, d.diag, topoReady, d.primordial, d.physicalDisks);
    renderRedundancy(d.virtualDisks, d.pools, d.physicalDisks);
    renderLayout(d.layout);

    // tiered virtual disk composition (stacked by tier / media)
    const tvd=(d.virtualDisks||[]).filter(v=>v.tiered && v.tiers && v.tiers.length);
    if(tvd.length){
      $('#tierCompWrap').style.display='';
      $('#tierComp').innerHTML=tvd.map(v=>{
        const tot=v.tiers.reduce((a,t)=>a+(t.size||0),0)||1;
        const seg=v.tiers.map(t=>`<span title="${t.name} — ${fmtBytes(t.size)}" style="width:${t.size/tot*100}%;background:${tierColor(t.mediaType)}"></span>`).join('');
        const legend=v.tiers.map(t=>`<span style="display:inline-block;margin:0 16px 4px 0">
          <span class="dot" style="background:${tierColor(t.mediaType)}"></span>${typeTag(t.mediaType)}
          <b>${t.name}</b> ${fmtBytes(t.size)}
          <span class="muted">${t.resiliency||''}${t.columns?(' · '+t.columns+' col'):''} · ${(t.size/tot*100).toFixed(0)}%</span></span>`).join('');
        return `<div data-ft="space" data-fk="${v.name}" title="Click to filter to this space" style="margin-bottom:18px;padding:4px">
          <div style="display:flex;justify-content:space-between;margin-bottom:6px">
            <span><b>${v.name}</b> <span class="muted">${v.resiliency||''} · ${v.provisioning||''}${v.writeCacheSize>0?' · WBC '+fmtBytes(v.writeCacheSize):''}</span></span>
            <span class="mono muted">${fmtBytes(tot)} across ${v.tiers.length} tiers · ${healthDot(v.health)}</span></div>
          <div class="stack">${seg}</div>
          <div style="margin-top:8px;font-size:12px">${legend}</div></div>`;
      }).join('');
    } else { $('#tierCompWrap').style.display='none'; }

    // physical disk status -> cached and merged into the unified disk table
    // (rendered by pollPerf at 500ms). Keyed by OS disk number to match perf rows.
    const nd={};
    (d.physicalDisks||[]).forEach(p=>{ nd[String(p.number)]=p; });
    topoDisks=nd;

    lastTopoData=d;
    applyTopoDerived(d);

    // tiers
    $('#tiers').innerHTML=d.tiers.length? d.tiers.map(t=>`<div style="display:flex;justify-content:space-between;padding:3px 0">
      <span>${typeTag(t.mediaType)} <b>${t.name}</b></span><span class="mono">${fmtBytes(t.size)}</span></div>`).join('')
      : '<span class="muted">No storage tiers configured.</span>';

    markActive();   // re-apply highlight after these tables were rebuilt
  }catch(e){ /* keep last-good */ }
}

// Realtime loop is self-scheduling (setTimeout after each response completes)
// so requests never pile up if one is briefly slow — critical at ~100ms.
initNav();
initTempToggle();
initPanelClose();
initPanelOrder();
initPanels();
initChartSpecs();
pollSystem();
setInterval(pollSystem, CFG.systemMs);   // CPU, file cache, Storage Spaces internals
(function perfLoop(){
  Promise.resolve(pollPerf()).catch(()=>{}).finally(()=>setTimeout(perfLoop, CFG.pollMs));
})();
// Slow path: capacity, health, redundancy, layout. Retries quickly until the
// storage collector has published, then settles into the (long) real cadence —
// otherwise a cold start would sit on "loading..." for a full interval.
let topoTimer=null;
function topoLoop(){
  clearTimeout(topoTimer);
  Promise.resolve(pollTopology()).catch(()=>{}).finally(()=>{
    topoTimer=setTimeout(topoLoop, topoReady ? CFG.topologyMs : 1500);
  });
}
topoLoop();
// The feed indicator doubles as a manual refresh, handy at a 30s+ cadence.
$('#feeds').title='click to refresh capacity/health now';
$('#feeds').style.cursor='pointer';
$('#feeds').addEventListener('click',topoLoop);
window.addEventListener('resize', drawSpark);
</script>
</body>
</html>
'@

# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------
function Send-Text {
    param($Context, [string]$Body, [string]$ContentType = 'text/html; charset=utf-8', [int]$Status = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.StatusCode  = $Status
    $Context.Response.ContentType = $ContentType
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

$prefix = if ($BindAll) { "http://+:$Port/" } else { "http://localhost:$Port/" }
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
} catch {
    Write-Host "`nFailed to start HTTP listener on $prefix" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($BindAll) {
        Write-Host "`nFor -BindAll you must reserve the URL (run once, elevated):" -ForegroundColor Yellow
        Write-Host "  netsh http add urlacl url=http://+:$Port/ user=Everyone" -ForegroundColor Yellow
        Write-Host "  New-NetFirewallRule -DisplayName 'Storage Dashboard' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow" -ForegroundColor Yellow
    } else {
        Write-Host "Try running this PowerShell window as Administrator." -ForegroundColor Yellow
    }
    return
}

# Spin up the background collectors, each in its own runspace. The HTTP loop
# below never blocks on storage because these threads own every slow call.
function Start-Worker {
    param([scriptblock]$Script, [object[]]$Arguments)
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $null = $ps.AddScript($Script)
    foreach ($a in $Arguments) { $null = $ps.AddArgument($a) }
    $handle = $ps.BeginInvoke()
    [pscustomobject]@{ ps = $ps; rs = $rs; handle = $handle }
}

$workers = @()
$workers += Start-Worker $SamplerScript @($script:Shared, $SampleMs)
$workers += Start-Worker $JobsScript    @($script:Shared, $JobsMs)
$workers += Start-Worker $StorageScript @($script:Shared, $TopologyMs)
$workers += Start-Worker $WearScript    @($script:Shared, $WearMs, [bool]$IncludeWear)
$workers += Start-Worker $LayoutScript  @($script:Shared, $LayoutMs, 200000, [bool]$ExactLayout, 20000)
$workers += Start-Worker $SystemScript  @($script:Shared, $SystemMs)

# Belt-and-braces: if the pipeline is torn down without running our finally
# block, this still tells the collector threads to exit (otherwise they'd keep
# sampling forever inside your PowerShell session). Deliberately does NOT set
# $e.Cancel, so normal Ctrl+C handling proceeds as usual.
try {
    $sharedRef = $script:Shared
    $script:CancelHandler = [ConsoleCancelEventHandler]({ $sharedRef['stop'] = $true }.GetNewClosure())
    [Console]::add_CancelKeyPress($script:CancelHandler)
} catch { }

$url = "http://localhost:$Port/"
Write-Host "`n  Storage Spaces Dashboard is live:" -ForegroundColor Green
Write-Host "    $url" -ForegroundColor Cyan
if ($BindAll) { Write-Host "    (also reachable at http://<this-server-ip>:$Port/ )" -ForegroundColor DarkCyan }
Write-Host ("    realtime {0}ms  ·  topology {1}s  ·  jobs {2}s  ·  wear {3}s  ·  layout {4}s" -f `
    $SampleMs, [int]($TopologyMs/1000), [int]($JobsMs/1000), [int]($WearMs/1000), [int]($LayoutMs/1000)) -ForegroundColor DarkGray
Write-Host "  Press Ctrl+C to stop.`n" -ForegroundColor DarkGray

if (-not $NoLaunch) { try { Start-Process $url } catch {} }

try {
    while ($listener.IsListening -and -not $script:Shared['stop']) {
        # GetContext() is a BLOCKING .NET call and PowerShell can only honour
        # Ctrl+C between statements — parked inside it, Ctrl+C is ignored.
        # GetContextAsync + a short timed wait returns control to PowerShell
        # every 200ms, so Ctrl+C is acted on promptly.
        $task = $listener.GetContextAsync()
        while (-not $task.AsyncWaitHandle.WaitOne(200)) {
            # print anything the background collectors queued
            while ($script:Shared['log'].Count -gt 0) {
                Write-Host ("  [{0:HH:mm:ss}] {1}" -f (Get-Date), $script:Shared['log'].Dequeue()) -ForegroundColor DarkYellow
            }
            if ($script:Shared['stop'] -or -not $listener.IsListening) { break }
        }
        while ($script:Shared['log'].Count -gt 0) {
            Write-Host ("  [{0:HH:mm:ss}] {1}" -f (Get-Date), $script:Shared['log'].Dequeue()) -ForegroundColor DarkYellow
        }
        if (-not $task.IsCompleted) { continue }   # shutting down
        try { $ctx = $task.GetAwaiter().GetResult() } catch { continue }
        try {
            switch ($ctx.Request.Url.AbsolutePath) {
                '/'              {
                    $page = $HtmlPage.Replace('__POLL_MS__', "$PollMs").Replace('__TOPO_MS__', "$TopologyMs").Replace('__SYS_MS__', "$SystemMs").Replace('__HOST__', $script:HostName)
                    Send-Text $ctx $page
                }
                '/api/perf'      {
                    $j = $script:Shared['perfJson']
                    if (-not $j) { $j = '{"timestamp":"","disks":[],"totals":{"readBps":0,"writeBps":0,"iops":0},"jobs":[]}' }
                    Send-Text $ctx $j 'application/json'
                }
                '/api/topology'  {
                    $j = $script:Shared['topoJson']
                    # "warming" lets the UI say "loading" instead of claiming there
                    # are no pools before the storage thread has published anything.
                    if (-not $j) { $j = '{"warming":true,"timestamp":"","pools":[],"virtualDisks":[],"tiers":[],"volumes":[],"physicalDisks":[],"layout":[]}' }
                    Send-Text $ctx $j 'application/json'
                }
                '/api/system'    {
                    $j = $script:Shared['systemJson']
                    if (-not $j) { $j = '{}' }
                    Send-Text $ctx $j 'application/json'
                }
                '/favicon.ico'   { Send-Text $ctx '' 'image/x-icon' 204 }
                default          { Send-Text $ctx 'Not found' 'text/plain' 404 }
            }
        } catch {
            try { Send-Text $ctx ("{`"error`":`"$($_.Exception.Message -replace '"','\"')`"}") 'application/json' 500 } catch {}
        }
    }
} finally {
    Write-Host "`n  Stopping..." -ForegroundColor DarkGray
    # Signal collectors to exit their loops. NOTE: do NOT call $ps.Stop() here —
    # it blocks until the runspace reaches a stoppable point and can hang for
    # minutes. The cooperative flag lets each loop unwind on its own.
    $script:Shared['stop'] = $true
    try { $listener.Stop() }  catch {}
    try { $listener.Close() } catch {}

    # Give them a moment to notice the flag (they check every ~100ms). A worker
    # that hasn't unwound by now is inside a slow storage call and won't finish
    # sooner by waiting longer, so keep this short.
    $deadline = [datetime]::UtcNow.AddMilliseconds(1500)
    while ([datetime]::UtcNow -lt $deadline) {
        if (-not ($workers | Where-Object { -not $_.handle.IsCompleted })) { break }
        Start-Sleep -Milliseconds 50
    }

    $stuck = 0
    foreach ($w in $workers) {
        if ($w.handle.IsCompleted) {
            try { $null = $w.ps.EndInvoke($w.handle) } catch {}
            try { $w.ps.Dispose() } catch {}
            try { $w.rs.Dispose() } catch {}
        } else {
            # Still inside a slow storage call. Disposing would block, so leave
            # it: it runs on a background thread, sees the flag, and unwinds.
            $stuck++
        }
    }
    if ($stuck) { Write-Host "  ($stuck collector(s) finishing a slow storage call in the background)" -ForegroundColor DarkGray }
    Write-Host "Dashboard stopped." -ForegroundColor DarkGray
}