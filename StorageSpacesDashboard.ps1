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
    [switch] $NoEventLog,       # don't mirror state changes to the Windows event log
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
    # ---- event timeline -------------------------------------------------
    # During triage, ORDERING IS CAUSALITY. "The drive went first, then the
    # space degraded, then the repair started" is a different incident from
    # "the repair started, then the space degraded". The dashboard could show
    # the current state of everything and never once tell you what happened
    # first.
    #
    # Lives on the SERVER, not in the browser: an incident you are diagnosing
    # is exactly when you reload the page, and a client-side log would be born
    # empty at that moment. Bounded, in-memory, dies with the process — no
    # file, no database, no retention policy, nothing that could itself break.
    events    = @()     # newest last; {t, sev, kind, name, from, to}
    evPrev    = $null   # last observed state map, for diffing
    evtLog    = $false  # true once the Application-log source is registered
    # ---- server-side history ------------------------------------------------
    # 1Hz downsample of the realtime feed, so a dashboard opened mid-incident
    # arrives with a past instead of a blank chart. Lists (not arrays): "$a +="
    # is O(n^2) and this is touched every second forever.
    histMax   = 900     # 15 minutes at 1Hz
    hist      = @{ t=[System.Collections.Generic.List[double]]::new()
                   r=[System.Collections.Generic.List[double]]::new()
                   w=[System.Collections.Generic.List[double]]::new()
                   i=[System.Collections.Generic.List[double]]::new()
                   d=@{} }
    histAcc   = @{ since=[datetime]::UtcNow; n=0; r=0.0; w=0.0; i=0.0; d=@{} }
    # Pool allocation over time, for the capacity forecast. One point a minute
    # is ample for a trend measured in days.
    capHist   = @{}     # poolName -> List of @{t,alloc,size}
    # drive serial (or uniqueId) -> human bay label, e.g. "shelf 2 bay 7".
    # Loaded from bays.json beside the script; the ONE piece of state this tool
    # keeps on disk, because it is knowledge only a human standing in front of
    # the hardware can supply and it must survive a restart.
    bays      = @{}
    # Drive identify LED. { uniqueId, until } — the topology collector turns it
    # back off when the deadline passes, so a light can never be left on.
    identify  = $null
    # Triage rule key -> 'hidden' | 'info' | 'warn'. Lets you tell the dashboard
    # that a given finding is not an emergency ON THIS MACHINE. Persisted to
    # alerts.json so the judgement survives a restart. Suppressed findings are
    # never silently dropped — the count is always on screen.
    alerts    = @{}
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
                # A counter that throws means "I don't know", NOT "zero". The old
                # code fell back to 0.0 for every metric, which for '% Idle Time'
                # made busy = 100 - 0 = 100 — so a drive whose counter instance had
                # vanished (i.e. the drive was PULLED) rendered pegged at 100% busy
                # for up to the 120s rebuild, then silently disappeared from the
                # table. Neither state said "failed". Track the failure instead.
                $ctrOk = $true
                foreach ($d in $defs) {
                    $v = $null
                    if ($per.ContainsKey($d.k)) { try { $v = [double]$per[$d.k].NextValue() } catch { $v = $null } }
                    else { $v = $null }
                    if ($null -eq $v) { $ctrOk = $false; $v = [double]0 }
                    $vals[$d.k] = $v
                }
                if ($ctrOk) {
                    $busy = 100 - $vals['idle']
                    if ($busy -lt 0)   { $busy = 0 }
                    if ($busy -gt 100) { $busy = 100 }
                } else {
                    $busy = $null   # UI renders "?" — never 0 (calm) and never 100 (alarm)
                }
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
                    countersOk     = $ctrOk
                    busy           = if ($null -eq $busy) { $null } else { [math]::Round($busy, 1) }
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

            # ---- server-side history ring ---------------------------------
            # Every number this dashboard has ever drawn lived in a browser ring
            # buffer that dies with the tab. So you would open the dashboard
            # DURING an incident and arrive with an empty chart, at the exact
            # moment the only question that matters is "what did the last
            # fifteen minutes look like?" — the tool had the least history
            # precisely when history was worth the most.
            #
            # The server has been sampling since boot. Keep a downsampled copy.
            # 1Hz for 15 minutes: 900 points per series, well under a megabyte
            # even on a 37-drive pool. In memory, bounded by construction, dies
            # with the process. No file, no schema, no retention policy, and
            # nothing that could itself be the thing that is broken.
            $now = [datetime]::UtcNow
            $acc = $Shared['histAcc']
            $acc['n']++
            $acc['r'] += [double]$totR; $acc['w'] += [double]$totW; $acc['i'] += [double]$totI
            foreach ($p in $phys) {
                $k = "$($p.diskNumber)"
                if (-not $acc['d'].ContainsKey($k)) { $acc['d'][$k] = @{ n=0; busy=0.0; r=0.0; w=0.0 } }
                $dd = $acc['d'][$k]
                $dd['n']++
                if ($null -ne $p.busy) { $dd['busy'] += [double]$p.busy }
                $dd['r'] += [double]$p.readBps; $dd['w'] += [double]$p.writeBps
            }

            if (($now - $acc['since']).TotalMilliseconds -ge 1000) {
                $h = $Shared['hist']
                $n = [math]::Max(1, $acc['n'])
                [void]$h['t'].Add([math]::Round(($now - [datetime]'1970-01-01').TotalSeconds))
                [void]$h['r'].Add([math]::Round($acc['r']/$n, 0))
                [void]$h['w'].Add([math]::Round($acc['w']/$n, 0))
                [void]$h['i'].Add([math]::Round($acc['i']/$n, 0))
                foreach ($k in $acc['d'].Keys) {
                    if (-not $h['d'].ContainsKey($k)) {
                        $h['d'][$k] = @{ busy=[System.Collections.Generic.List[double]]::new()
                                         r   =[System.Collections.Generic.List[double]]::new()
                                         w   =[System.Collections.Generic.List[double]]::new() }
                    }
                    $dd = $acc['d'][$k]; $dn = [math]::Max(1, $dd['n'])
                    [void]$h['d'][$k]['busy'].Add([math]::Round($dd['busy']/$dn, 1))
                    [void]$h['d'][$k]['r'].Add([math]::Round($dd['r']/$dn, 0))
                    [void]$h['d'][$k]['w'].Add([math]::Round($dd['w']/$dn, 0))
                }
                # Trim in one RemoveRange rather than repeated shifts.
                $max = [int]$Shared['histMax']
                foreach ($key in @('t','r','w','i')) {
                    if ($h[$key].Count -gt $max) { $h[$key].RemoveRange(0, $h[$key].Count - $max) }
                }
                foreach ($k in @($h['d'].Keys)) {
                    foreach ($s in @('busy','r','w')) {
                        if ($h['d'][$k][$s].Count -gt $max) { $h['d'][$k][$s].RemoveRange(0, $h['d'][$k][$s].Count - $max) }
                    }
                }
                $Shared['histAcc'] = @{ since=$now; n=0; r=0.0; w=0.0; i=0.0; d=@{} }
            }
        } catch {}
        # Interruptible sleep: check the stop flag every 100ms so shutdown is
        # prompt even for the 5s storage loop.
        Wait-Interval $Shared $IntervalMs
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
        Wait-Interval $Shared $IntervalMs
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
        Wait-Interval $Shared $IntervalMs
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

                # SMART's own "this drive is about to die" flag, which is a
                # DIFFERENT signal from Storage Spaces' "Predictive Failure"
                # operational status — the drive's firmware raises this one, and
                # Storage Spaces does not always surface it. Read once per sweep
                # for the whole machine rather than per drive.
                $predict = @{}
                try {
                    foreach ($fp in (Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)) {
                        # InstanceName looks like "SCSI\Disk...&0000_0". Key on the
                        # leading portion so it can be matched loosely below.
                        $predict["$($fp.InstanceName)"] = [pscustomobject]@{
                            failing = [bool]$fp.PredictFailure
                            reason  = [int]$fp.Reason
                        }
                    }
                } catch {}
                $anyPredict = @($predict.Values | Where-Object { $_.failing }).Count

                foreach ($pd in $all) {
                    if ($Shared['stop']) { break }
                    try {
                        $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
                        # TemperatureMax is the DRIVE'S OWN rated maximum. Comparing
                        # against a fixed number is how you either cry wolf about a
                        # warm NVMe or stay silent about a cooking spindle — the
                        # safe operating range is a property of the drive, not a
                        # constant.
                        $tmax = $null
                        try { if ($null -ne $rc.TemperatureMax -and [double]$rc.TemperatureMax -gt 0) { $tmax = [double]$rc.TemperatureMax } } catch {}
                        $wt["$($pd.UniqueId)"] = [pscustomobject]@{
                            wear = $rc.Wear; temp = $rc.Temperature; tempMax = $tmax
                            readErr  = $rc.ReadErrorsTotal
                            writeErr = $rc.WriteErrorsTotal
                            powerOnHours = $rc.PowerOnHours
                            # Any drive on this box flagged by SMART; matched per
                            # drive below where the instance name allows it.
                            smartFailing = $null
                        }
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
                # Machine-wide SMART verdict. Reported separately and honestly:
                # WMI's instance names cannot be reliably joined to Storage Spaces
                # UniqueIds, so claiming WHICH drive would be a guess. Saying "SMART
                # is predicting failure somewhere on this box" is true and
                # actionable; naming the wrong drive would not be.
                $Shared['smart'] = [pscustomobject]@{
                    checked = $predict.Count
                    failing = $anyPredict
                    at      = (Get-Date).ToString('o')
                }
            } catch {}
        }
        Wait-Interval $Shared $IntervalMs
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
        Wait-Interval $Shared $IntervalMs
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
                    # Why a drive is NOT poolable: In a pool / Not healthy /
                    # Offline / Insufficient capacity / Removable media / ...
                    # "CanPool: False" on its own is a fact you can do nothing with.
                    cannotPoolReason = (@($pd.CannotPoolReason | ForEach-Object { "$_" } | Where-Object { $_ }) -join ', ')
                    deviceId  = "$($pd.DeviceId)"
                    name      = "$($pd.FriendlyName)"
                    mediaType = "$($pd.MediaType)"
                    busType   = "$($pd.BusType)"
                    usage     = "$($pd.Usage)"
                    size      = [double]$pd.Size
                    health    = "$($pd.HealthStatus)"
                    # OperationalStatus is a COLLECTION ("OK", or "Lost Communication",
                    # or several at once). Plain "$(...)" joins an array with spaces,
                    # which is unsplittable because the values themselves contain
                    # spaces. Join explicitly so the UI can separate them.
                    opStatus  = (@($pd.OperationalStatus | ForEach-Object { "$_" }) -join ', ')
                    wear      = if ($w) { [double]$w.wear } else { $null }
                    tempC     = if ($w) { [double]$w.temp } else { $null }
                    # The drive's OWN rated maximum, so "too hot" is measured
                    # against this drive rather than a number someone picked.
                    tempMaxC  = if ($w -and $null -ne $w.tempMax) { [double]$w.tempMax } else { $null }
                    readErr   = if ($w) { $w.readErr }  else { $null }
                    writeErr  = if ($w) { $w.writeErr } else { $null }
                    powerOnHours = if ($w) { $w.powerOnHours } else { $null }
                    # ---- physical identity, for the bay map ----------------
                    # The last mile of every triage is physical: the dashboard
                    # can tell you disk 7 is dead and still leave you standing
                    # in front of 37 identical drives.
                    #
                    # serial is the key the bay map is stored against — it is
                    # printed on the drive itself, survives reboots, re-cabling
                    # and moving the disk to another port, and is the one thing
                    # you can read while holding the thing. uniqueId is the
                    # fallback for drives that report no serial.
                    serial    = "$($pd.SerialNumber)".Trim()
                    uniqueId  = "$($pd.UniqueId)"
                    # Whatever the hardware volunteers. Absent on most direct-
                    # attach consumer kit, present on real SES enclosures.
                    slot      = if ($null -ne $pd.SlotNumber) { "$($pd.SlotNumber)" } else { '' }
                    enclosure = if ($null -ne $pd.EnclosureNumber) { "$($pd.EnclosureNumber)" } else { '' }
                    physLoc   = "$($pd.PhysicalLocation)"
                    bay       = ''   # filled in below from bays.json
                }
            }

            # ---- bay map -------------------------------------------------------
            # Resolve each drive to a human bay label. Precedence:
            #   1. what YOU wrote in bays.json, keyed by serial (or uniqueId)
            #   2. what the ENCLOSURE reports, if the hardware has SES
            # Your label always wins: if you have relabelled the drawers, the
            # enclosure's idea of slot 3 is not the sticker you put on it.
            try {
                $bays = $Shared['bays']
                foreach ($p in $physList) {
                    $key = if ($p.serial) { $p.serial } else { $p.uniqueId }
                    $lbl = ''
                    if ($bays -and $key -and $bays.ContainsKey($key)) { $lbl = "$($bays[$key])" }
                    elseif ($p.enclosure -ne '' -and $p.slot -ne '') { $lbl = "encl $($p.enclosure) slot $($p.slot)" }
                    elseif ($p.slot -ne '')                          { $lbl = "slot $($p.slot)" }
                    $p.bay = $lbl
                }
            } catch {}

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
                        name = "$($pool.FriendlyName)"; health = $hs
                        opStatus = (@($pool.OperationalStatus | ForEach-Object { "$_" }) -join ', ')
                        # WHY it is read-only, which changes everything. "Incomplete"
                        # means the pool lost quorum — most drives are gone — and is a
                        # catastrophe. "Policy" means an administrator set it, and is a
                        # Tuesday. Rendering both as the bare word "Read-only" tells you
                        # the state and hides the emergency.
                        isReadOnly = [bool]$pool.IsReadOnly
                        readOnlyReason = "$($pool.ReadOnlyReason)"
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
                        name = "$($vd.FriendlyName)"; health = "$($vd.HealthStatus)"
                        opStatus = (@($vd.OperationalStatus | ForEach-Object { "$_" }) -join ', ')
                        # "Detached" alone is ambiguous: By Policy is deliberate,
                        # Majority Disks Unhealthy means the data may be gone.
                        detachedReason = "$($vd.DetachedReason)"
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
            # ---- event timeline: diff this pass against the last -------------
            # Deliberately diffs the FLAT state (health + operational status per
            # named object) rather than the whole payload, so a byte that moved
            # in a capacity figure does not read as an event. Only transitions
            # a human would call something happening.
            try {
                $curr = @{}
                foreach ($p in $physList) { $curr["drive|$($p.name)"] = "$($p.health) / $($p.opStatus) / $($p.usage)" }
                foreach ($p in $pools)    { $curr["pool|$($p.name)"]  = "$($p.health) / $($p.opStatus)" }
                foreach ($v in $vdisks)   { $curr["space|$($v.name)"] = "$($v.health) / $($v.opStatus)" }

                $prev = $Shared['evPrev']
                if ($prev) {
                    $new = @()
                    foreach ($k in $curr.Keys) {
                        $was = $prev[$k]
                        if ($null -eq $was) {
                            $new += [pscustomobject]@{ t=(Get-Date).ToString('o'); kind=($k -split '\|')[0]
                                                       name=($k -split '\|',2)[1]; from=''; to=$curr[$k]; verb='appeared' }
                        } elseif ($was -ne $curr[$k]) {
                            $new += [pscustomobject]@{ t=(Get-Date).ToString('o'); kind=($k -split '\|')[0]
                                                       name=($k -split '\|',2)[1]; from=$was; to=$curr[$k]; verb='changed' }
                        }
                    }
                    foreach ($k in $prev.Keys) {
                        if (-not $curr.ContainsKey($k)) {
                            $new += [pscustomobject]@{ t=(Get-Date).ToString('o'); kind=($k -split '\|')[0]
                                                       name=($k -split '\|',2)[1]; from=$prev[$k]; to=''; verb='disappeared' }
                        }
                    }
                    if ($new.Count) {
                        # Bounded ring: 300 entries is hours of a normal system and
                        # minutes of a thrashing one, which is the case that matters.
                        $all = @($Shared['events']) + $new
                        if ($all.Count -gt 300) { $all = $all[($all.Count-300)..($all.Count-1)] }
                        $Shared['events'] = @($all)

                        # Mirror to the Windows event log. NOT an alerting engine —
                        # the opposite. Whatever you already run (a scheduled task,
                        # a monitoring agent, Event Viewer at 2am) picks these up
                        # for free, and this script never has to own notification,
                        # retention, or an SMTP config.
                        if ($Shared['evtLog']) {
                            foreach ($n in $new) {
                                try {
                                    $isBad = ($n.verb -eq 'disappeared') -or
                                             ($n.to -match 'Unhealthy|Lost Communication|Detached|Not Responding|IO Error|Split')
                                    $isWarn= ($n.to -match 'Warning|Degraded|Incomplete|Predictive|Stale|Unrecognized|Retired')
                                    $type  = if ($isBad) { 'Error' } elseif ($isWarn) { 'Warning' } else { 'Information' }
                                    # Skip the routine: only transitions worth waking for.
                                    if ($type -eq 'Information' -and $n.verb -ne 'disappeared') { continue }
                                    Write-EventLog -LogName Application -Source 'StorageSpacesDashboard' `
                                        -EventId $(if ($isBad) { 9001 } elseif ($isWarn) { 9002 } else { 9003 }) `
                                        -EntryType $type `
                                        -Message ("{0} '{1}' {2}: {3} -> {4}" -f $n.kind, $n.name, $n.verb, $n.from, $n.to) `
                                        -ErrorAction Stop
                                } catch {}
                            }
                        }
                    }
                }
                $Shared['evPrev'] = $curr
            } catch {}

            # ---- identify LED auto-off -----------------------------------------
            # Nobody should have to remember to turn a light off, and a blinking
            # drive that was fine is exactly the kind of false signal this
            # dashboard exists to avoid. Deadline lives in shared state; this
            # collector is already running, so it does the switching off.
            try {
                $idf = $Shared['identify']
                if ($idf -and [datetime]::UtcNow -ge $idf.until) {
                    $target = Get-PhysicalDisk -UniqueId $idf.uniqueId -ErrorAction SilentlyContinue
                    if ($target) {
                        try   { Disable-PhysicalDiskIndication    -InputObject $target -ErrorAction Stop }
                        catch { try { Disable-PhysicalDiskIdentification -InputObject $target -ErrorAction Stop } catch {} }
                    }
                    $Shared['identify'] = $null
                }
            } catch { $Shared['identify'] = $null }

            # ---- ReFS data integrity ------------------------------------------
            # A whole class of failure this dashboard was blind to: silent
            # corruption. ReFS only checksums FILE DATA when integrity streams
            # are enabled, which is OFF BY DEFAULT — so a volume can be
            # "Healthy" while quietly rotting, and Storage Spaces' resiliency
            # cannot repair what nothing detected.
            #
            # Three things worth knowing, none of which any other panel shows:
            #   1. is there a ReFS volume at all
            #   2. when did the Data Integrity Scan last run, and did it succeed
            #      (scheduled task, default cadence is every four weeks)
            #   3. has ReFS logged any corruption — it writes them to the System
            #      log, including whether it managed to fix them
            #
            # Recomputed at most every 5 minutes: Get-ScheduledTask and
            # Get-WinEvent are far too slow for the 5s topology cadence.
            try {
                $lastInt = $Shared['integrityAt']
                if (-not $lastInt -or ([datetime]::UtcNow - $lastInt).TotalSeconds -ge 300) {
                    $refsVols = @()
                    try {
                        $refsVols = @(Get-Volume -ErrorAction Stop |
                            Where-Object { "$($_.FileSystem)" -match 'ReFS' } |
                            ForEach-Object {
                                [pscustomobject]@{
                                    drive  = if ($_.DriveLetter) { "$($_.DriveLetter):" } else { "$($_.FileSystemLabel)" }
                                    label  = "$($_.FileSystemLabel)"
                                    health = "$($_.HealthStatus)"
                                }
                            })
                    } catch {}

                    $scan = $null
                    try {
                        $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Data Integrity Scan\' -ErrorAction Stop |
                             Select-Object -First 1
                        if ($t) {
                            $i = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
                            $scan = [pscustomobject]@{
                                name    = "$($t.TaskName)"
                                state   = "$($t.State)"
                                # Task Scheduler returns a SENTINEL date for "never
                                # run" — 1899-12-30 or 1999-11-30 depending on the
                                # API path. A `.Year -gt 1900` guard let the 1999
                                # one through and the UI cheerfully reported "last
                                # ran 9732 days ago". Anything before 2000 is not a
                                # date, it is the absence of one.
                                lastRun = if ($i -and $i.LastRunTime -and $i.LastRunTime.Year -ge 2000) { $i.LastRunTime.ToString('o') } else { $null }
                                nextRun = if ($i -and $i.NextRunTime -and $i.NextRunTime.Year -ge 2000) { $i.NextRunTime.ToString('o') } else { $null }
                                # 0 is success; 267011 means "has never run".
                                lastResult = if ($i) { [int]$i.LastTaskResult } else { $null }
                            }
                        }
                    } catch {}

                    # ReFS corruption events from the System log. Bounded lookback
                    # and count so a machine with a screaming log cannot stall the
                    # collector.
                    $corrupt = @()
                    try {
                        $corrupt = @(Get-WinEvent -FilterHashtable @{
                                        LogName='System'
                                        ProviderName='Microsoft-Windows-ReFS','Microsoft-Windows-DataIntegrityScan'
                                        StartTime=(Get-Date).AddDays(-30)
                                     } -MaxEvents 25 -ErrorAction Stop |
                            ForEach-Object {
                                [pscustomobject]@{
                                    t     = $_.TimeCreated.ToString('o')
                                    id    = [int]$_.Id
                                    level = "$($_.LevelDisplayName)"
                                    src   = "$($_.ProviderName)"
                                    msg   = ("$($_.Message)" -split "`r?`n")[0]
                                }
                            })
                    } catch {}

                    $Shared['integrity'] = [pscustomobject]@{
                        refsVolumes = @($refsVols)
                        scan        = $scan
                        events      = @($corrupt)
                        checkedAt   = (Get-Date).ToString('o')
                    }
                    $Shared['integrityAt'] = [datetime]::UtcNow
                }
            } catch {}

            # ---- capacity trend, for the forecast --------------------------
            # One sample a minute. A pool fills over days or months, so a denser
            # series buys nothing and just makes the payload bigger.
            try {
                $ch = $Shared['capHist']
                $nowS = [math]::Round(([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds)
                foreach ($p in $pools) {
                    if (-not $ch.ContainsKey($p.name)) {
                        $ch[$p.name] = [System.Collections.Generic.List[object]]::new()
                    }
                    $lst = $ch[$p.name]
                    if ($lst.Count -eq 0 -or ($nowS - [double]$lst[$lst.Count-1].t) -ge 60) {
                        [void]$lst.Add([pscustomobject]@{ t=$nowS; alloc=[double]$p.allocated; size=[double]$p.size })
                        # 3 days at 1/min. Long enough to see a real trend, short
                        # enough that the payload stays trivial.
                        if ($lst.Count -gt 4320) { $lst.RemoveRange(0, $lst.Count - 4320) }
                    }
                }
            } catch {}

            $topo | Add-Member -NotePropertyName events -NotePropertyValue @($Shared['events']) -Force
            $topo | Add-Member -NotePropertyName integrity -NotePropertyValue $Shared['integrity'] -Force
            $topo | Add-Member -NotePropertyName smart -NotePropertyValue $Shared['smart'] -Force
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
        # This one sleeps for a SELF-LIMITED interval, not the configured one —
        # the topology collector backs off to its own scan duration when a pass
        # runs long. Same helper, different argument.
        Wait-Interval $Shared $sleepMs
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
  /* ---- tokens -------------------------------------------------------------
     One place for every colour. Dark is the default and stays byte-identical to
     what shipped; light is a real theme, not an inversion — the status hues are
     re-picked for contrast on a pale ground rather than reused, because #3fb950
     on white is unreadable and #d29922 is worse.

     Resolution order:  [data-theme] on <html>  >  OS preference  >  dark.
     Canvas cannot resolve var(), so chart code reads these through cssVar() and
     caches them per theme — see TC / refreshThemeColors(). */
  :root{
    --bg:#0e1116; --panel:#171b22; --panel2:#1f2530; --border:#2a3140;
    --text:#e6edf3; --muted:#8b98a9; --accent:#4aa3ff; --good:#3fb950;
    --warn:#d29922; --bad:#f85149; --read:#4aa3ff; --write:#bc8cff;
    --shadow:0 1px 2px rgba(0,0,0,.4);
    --fill-a:.16;            /* chart area-fill alpha, per theme */
    --hi:#12324a; --hi-br:#1d4d70; --hi-fg:#7cc4ff;
    --alert-fg:#ff9b95; --alert-bg:#3a1518;
    --warnstate-fg:#e8bd6d; --warnstate-bg:#38290f;
    /* Halo behind text that sits ON TOP of a coloured bar, so it stays legible
       whatever colour the fill is. It must match the BACKGROUND, not the text —
       a black glow behind near-black text on the light theme reads as blur, not
       contrast. That is what made the bar labels look smudged. */
    --halo:0 0 3px rgba(0,0,0,.75), 0 0 6px rgba(0,0,0,.45);
    --stackdiv:rgba(0,0,0,.35);
    --backdrop:rgba(0,0,0,.66);
  }
  @media (prefers-color-scheme: light){
    :root:not([data-theme="dark"]){
      --bg:#f4f6f9; --panel:#ffffff; --panel2:#eef1f5; --border:#d6dce4;
      --text:#131a22; --muted:#5a6675; --accent:#0a63c9; --good:#1a7f37;
      --warn:#8a5c00; --bad:#cf222e; --read:#0a63c9; --write:#7b3fd4;
      --shadow:0 1px 2px rgba(16,24,40,.08);
      --fill-a:.13;
      --hi:#dbeafe; --hi-br:#9dc4f5; --hi-fg:#0a4fa3;
      --alert-fg:#a4161a; --alert-bg:#fbe3e4;
      --warnstate-fg:#7a4b00; --warnstate-bg:#fdf0d5;
      --halo:0 0 3px rgba(255,255,255,.95), 0 0 7px rgba(255,255,255,.8);
      --stackdiv:rgba(255,255,255,.55);
      --backdrop:rgba(30,38,48,.55);
    }
  }
  :root[data-theme="light"]{
    --bg:#f4f6f9; --panel:#ffffff; --panel2:#eef1f5; --border:#d6dce4;
    --text:#131a22; --muted:#5a6675; --accent:#0a63c9; --good:#1a7f37;
    --warn:#8a5c00; --bad:#cf222e; --read:#0a63c9; --write:#7b3fd4;
    --shadow:0 1px 2px rgba(16,24,40,.08);
    --fill-a:.13;
    --hi:#dbeafe; --hi-br:#9dc4f5; --hi-fg:#0a4fa3;
    --alert-fg:#a4161a; --alert-bg:#fbe3e4;
    --warnstate-fg:#7a4b00; --warnstate-bg:#fdf0d5;
    --halo:0 0 3px rgba(255,255,255,.95), 0 0 7px rgba(255,255,255,.8);
    --stackdiv:rgba(255,255,255,.55);
    --backdrop:rgba(30,38,48,.55);
  }
  /* Respect the OS. The failed-drive dot pulses forever, which is exactly the
     kind of thing that is a problem for vestibular disorders — and it is
     guaranteed to be on screen during the worst moment. Motion goes, the signal
     does NOT: a heavier ring replaces it. */
  @media (prefers-reduced-motion: reduce){
    *,*::before,*::after{animation-duration:.001ms!important;animation-iteration-count:1!important;
      transition-duration:.001ms!important;scroll-behavior:auto!important}
    .ndot.bad{box-shadow:0 0 0 3px rgba(248,81,73,.30),0 0 0 5px rgba(248,81,73,.18)}
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--text);
    font:14px/1.4 "Segoe UI",system-ui,sans-serif}
  header{display:flex;align-items:center;gap:16px;padding:14px 20px;
    border-bottom:1px solid var(--border);background:var(--panel);position:sticky;top:0;z-index:5}
  header h1{font-size:16px;margin:0;font-weight:600}
  /* which server am I looking at — deliberately high contrast */
  .hostchip{font-size:13px;font-weight:700;letter-spacing:.4px;color:var(--hi-fg);
    background:var(--hi);border:1px solid var(--hi-br);border-radius:6px;padding:3px 10px;
    white-space:nowrap;text-transform:uppercase}
  /* Theme toggle. Fixed width so switching the glyph cannot reflow the header. */
  .themebtn{margin-left:auto;background:var(--panel2);border:1px solid var(--border);
    color:var(--muted);border-radius:6px;width:30px;height:26px;cursor:pointer;
    font-size:14px;line-height:1;display:flex;align-items:center;justify-content:center;flex:none}
  .themebtn:hover{color:var(--text);border-color:var(--muted)}
  .dot{width:9px;height:9px;border-radius:50%;display:inline-block;margin-right:6px}
  .status{color:var(--muted);font-size:12px}
  /* shell: fixed left nav + scrolling content */
  .shell{display:flex;align-items:flex-start}
  .side{width:186px;flex:none;background:var(--panel);border-right:1px solid var(--border);
    padding:12px 9px;position:sticky;top:52px;height:calc(100vh - 52px);overflow:auto}
  /* .navitem is a real <button> so it is reachable by keyboard. The reset keeps
     it looking identical; without `font:inherit` a button drops to the UA font. */
  .navitem{padding:9px 11px;border-radius:8px;cursor:pointer;font-size:13px;color:var(--muted);
    display:flex;align-items:center;gap:9px;margin-bottom:2px;user-select:none;white-space:nowrap;
    width:100%;text-align:left;background:none;border:0;font-family:inherit;line-height:1.4}
  .navitem:hover{background:var(--panel2);color:var(--text)}
  /* ---- focus -------------------------------------------------------------
     There were previously ZERO focusable elements and zero focus styles: every
     control was a <div> with a click handler, so the dashboard could not be
     operated by keyboard at all. That is not a compliance checkbox - it is
     being unable to move around the UI at 2am over laggy RDP. */
  :focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:6px}
  .navitem:focus-visible{outline-offset:-2px}
  /* Never remove the outline without replacing it. */
  :focus:not(:focus-visible){outline:none}
  .skiplink{position:absolute;left:-9999px;top:0;z-index:50;background:var(--accent);color:#04121f;
    padding:9px 14px;border-radius:0 0 8px 0;font-weight:600;font-size:13px}
  .skiplink:focus{left:0}
  /* Rows that filter the dashboard when clicked are keyboard-activatable too. */
  tr[data-ft]{cursor:pointer}
  tr[data-ft]:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}
  .navitem.active{background:var(--hi);color:var(--hi-fg);font-weight:600}
  .navitem .nb{margin-left:auto;font-size:10px;color:var(--muted);font-weight:400}
  /* Inline SVG at currentColor: the icon inherits the item's state colour, so an
     alerting section's glyph turns red with its label. Emoji could never do this. */
  .nicon{width:16px;height:16px;flex:none;fill:none;stroke:currentColor;stroke-width:1.6;
    opacity:.85;overflow:visible}
  .navitem.active .nicon,.navitem:hover .nicon{opacity:1}
  /* at-a-glance health, visible from every tab */
  .ndot{width:8px;height:8px;border-radius:50%;flex:none;display:none}
  .ndot.ok{display:inline-block;background:var(--good);box-shadow:0 0 0 3px rgba(63,185,80,.16)}
  .ndot.warn{display:inline-block;background:var(--warn);box-shadow:0 0 0 3px rgba(210,153,34,.20)}
  .ndot.bad{display:inline-block;background:var(--bad);box-shadow:0 0 0 3px rgba(248,81,73,.22);
    animation:pulse 1.8s ease-in-out infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.35}}
  /* Tokenized. These were #ff9b95 / #3a1518 / #e8bd6d — pale pink, near-black
     maroon and pale gold, all picked for a dark ground. On the light theme the
     alerting nav item rendered as a dark maroon block in an otherwise white
     rail, and the warn/alert labels sat at roughly 2:1 contrast on white. The
     ALERTING items are the ones that must stay readable, so they cannot be the
     ones left behind by a theme. */
  .navitem.alert{color:var(--alert-fg)}
  .navitem.alert.active{color:var(--alert-fg);background:var(--alert-bg)}
  .navitem.warnstate{color:var(--warnstate-fg)}
  .navitem.warnstate.active{color:var(--warnstate-fg);background:var(--warnstate-bg)}
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
  /* Found by lab/jitter-check.js, and it was here before that file existed.
     tabular-nums makes every DIGIT the same width; it does nothing about the
     digit COUNT. So a CPU value going 9 -> 38 -> 100 grew this span from 15px
     to 30px and shoved the "%" beside it sideways, ten times a second. The
     sparkline labels were given a fixed width for exactly this reason (see the
     note above) — the KPI values were missed.
     min-width is a mitigation, not a proof: a value wider than the reserve
     still pushes. 4.5ch covers 0-100%, 0.0-9999 MB/s and the IOPS range. */
  .kpi .v{font-size:26px;font-weight:700;display:inline-block;min-width:4.5ch}
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
    font-style:normal;font-size:11px;color:var(--text);text-shadow:var(--halo)}
  .tag{font-size:11px;padding:1px 7px;border-radius:10px;background:var(--panel2);color:var(--muted)}
  .tag.ssd{background:#12324a;color:#7cc4ff}
  .tag.hdd{background:#2a2233;color:#c9a7ff}
  .tag.scm{background:#0f3a2e;color:#6fd7b0}
  .tag.space{background:#3a2a12;color:#f0c07a}
  /* OperationalStatus chip. Only rendered when the status is NOT plain OK, so
     its mere presence is the signal — a badge that is always there is a badge
     nobody reads at 2am. */
  .optag{display:inline-block;font-size:11px;padding:0 6px;border-radius:9px;
         margin-left:6px;border:1px solid currentColor;white-space:nowrap;line-height:16px}
  .unkval{color:var(--muted);font-style:italic}
  /* Stale-data badge. Sits opposite the panel controls, only exists when the
     feed behind that panel is genuinely late. Deliberately loud: a panel
     quietly showing old numbers is worse than one showing none. */
  /* Physical bay. Deliberately the loudest non-alarm thing on a triage row —
     it is the only field that tells you what to DO with your hands. */
  .baytag{display:inline-block;font-size:11px;padding:0 7px;border-radius:9px;
    background:var(--hi);color:var(--hi-fg);border:1px solid var(--hi-br);
    white-space:nowrap;line-height:16px;font-weight:600}
  #bayTbl input{width:100%;background:var(--panel2);border:1px solid var(--border);
    color:var(--text);border-radius:5px;padding:4px 7px;font-family:inherit;font-size:12px}
  #bayTbl input:focus-visible{outline:2px solid var(--accent);outline-offset:1px}
  #bayTbl input:disabled{opacity:.5;cursor:not-allowed}
  .agetag{position:absolute;top:7px;left:12px;font-size:10px;line-height:16px;
    padding:0 7px;border-radius:9px;z-index:4;white-space:nowrap;
    background:var(--warn);color:#1b1300;font-weight:700;letter-spacing:.2px}
  .card.kpi>.agetag{top:5px;left:8px;font-size:9px}
  /* A drive the storage stack still lists but Windows has stopped collecting
     I/O for. It used to just disappear from this table. Struck through, not
     hidden — the row must remain, and must not look like a working drive. */
  #diskTbl tbody tr.absent{background:color-mix(in srgb,var(--bad) 7%,transparent)}
  #diskTbl tbody tr.absent .e-name{text-decoration:line-through;text-decoration-color:var(--bad)}
  /* triage rows: fixed row height so a changing list cannot reflow the page */
  .trow{display:flex;align-items:center;gap:10px;padding:8px 12px;margin-bottom:6px;
    background:var(--panel2);border-radius:0 8px 8px 0;min-height:38px;flex-wrap:wrap}
  .trow .tkind{font-size:10px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted);
    min-width:46px;flex:none}
  .trow .twhy{font-size:13px;font-weight:600}
  .trow .muted{font-size:12px;margin-left:auto}
  /* A suppressed finding stays legible — dimmed, never deleted. */
  .trow.rmuted{opacity:.62}
  .mutetag{font-size:10px;text-transform:uppercase;letter-spacing:.4px;color:var(--muted);
    border:1px dashed var(--border);border-radius:8px;padding:0 6px;line-height:15px}
  .rowacts{display:flex;gap:5px;margin-left:8px}
  .ract{font-size:10px;padding:1px 7px;border-radius:8px;cursor:pointer;font-family:inherit;
    background:none;color:var(--muted);border:1px solid var(--border);white-space:nowrap}
  .ract:hover{color:var(--text);border-color:var(--muted)}
  .trow:not(:hover) .rowacts{opacity:0}
  .trow:hover .rowacts,.rowacts:focus-within{opacity:1}
  /* Suppression is NEVER invisible. This bar is present whenever anything is
     muted, including when the list is otherwise empty. */
  .supbar{display:flex;align-items:center;gap:10px;margin-top:10px;padding:7px 12px;
    border:1px dashed var(--border);border-radius:8px;font-size:12px;color:var(--muted)}
  .supbar button{font-size:11px;padding:1px 9px;border-radius:8px;cursor:pointer;font-family:inherit;
    background:none;color:var(--accent);border:1px solid var(--border)}
  /* The remedy. Wraps to its own line so a long command cannot squeeze the
     finding itself, and it is COPYABLE, never runnable — this dashboard reads
     the storage stack, it does not repair it. */
  .fixrow{flex-basis:100%;display:flex;align-items:center;gap:8px;flex-wrap:wrap;
    margin-top:6px;padding-top:6px;border-top:1px dashed var(--border)}
  .fixnote{font-size:12px;color:var(--muted)}
  .fixcmd{font-family:ui-monospace,Consolas,monospace;font-size:11.5px;background:var(--bg);
    border:1px solid var(--border);border-radius:5px;padding:2px 7px;color:var(--text);
    white-space:pre;overflow-x:auto;max-width:100%}
  a.ract{text-decoration:none;line-height:15px}
  .ract.bad{color:var(--bad);border-color:var(--bad)}
  .blinkbtn{font-size:10px;margin-left:8px;padding:1px 8px;border-radius:8px;cursor:pointer;
    font-family:inherit;background:none;color:var(--accent);border:1px solid var(--border)}
  .blinkbtn.on{background:var(--accent);color:#04121f;border-color:var(--accent)}
  .blinkbtn.bad{color:var(--bad);border-color:var(--bad)}
  .blinkbtn:disabled{cursor:default}
  /* resizable + scrollable panel bodies (drag the bottom-right corner) */
  /* No native `resize`: its grip lives in the bottom-right corner, under the
     full-bleed canvas and clipped by overflow:hidden, so it was invisible. A
     custom .reszgrip (added in initPanels) replaces it — a normal-flow bar
     BELOW the body, so it never overlaps chart or table content. */
  .pbody{overflow:auto;min-height:70px;position:relative}
  .reszgrip{height:13px;cursor:ns-resize;display:flex;align-items:center;justify-content:center;
    touch-action:none;user-select:none;margin-top:2px}
  .reszgrip::before{content:'';width:38px;height:3px;border-radius:3px;background:var(--border);
    transition:background .12s,width .12s}
  .reszgrip:hover::before{background:var(--muted);width:54px}
  .reszgrip:active::before{background:var(--accent)}
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
  .modal{position:fixed;inset:0;background:var(--backdrop);z-index:60;
    display:flex;align-items:center;justify-content:center;padding:26px}
  .modalbox{background:var(--panel);border:1px solid var(--border);border-radius:12px;
    width:min(1150px,95vw);padding:15px 18px 13px;box-shadow:0 18px 50px rgba(0,0,0,.5)}
  .modalhdr{display:flex;align-items:center;gap:12px;margin-bottom:10px}
  .modalhdr b{font-size:15px}
  .modalbody{height:56vh;min-height:220px;overflow:hidden;resize:vertical;
    background:var(--bg);border-radius:8px;padding:4px}
  #modalCanvas{width:100%;height:100%;display:block}
  #modalStats{margin-top:10px;font-size:12px}
  canvas.mini,#spark,#histChart{cursor:zoom-in}
  .mini{width:100%;height:22px;display:block}
  .cellspark{display:flex;align-items:center;gap:8px}
  .cellspark canvas{flex:1;min-width:60px;background:var(--panel2);border-radius:3px}
  /* Fixed width, NOT min-width: a growing label would shrink the flex canvas
     next to it and make the graph itself visibly resize every update. */
  .cellspark span{width:56px;flex:none;text-align:right;font-size:12px;white-space:nowrap;overflow:hidden}
  .stack{display:flex;height:22px;border-radius:5px;overflow:hidden;background:var(--panel2)}
  .stack>span{display:block;height:100%;border-right:1px solid var(--stackdiv)}
  .stack>span:last-child{border-right:none}
  .mono{font-variant-numeric:tabular-nums}
  .muted{color:var(--muted)}
  .sec{margin-bottom:16px}
  #spark,#histChart{width:100%;height:100%;display:block}
  .kspark{width:100%;height:28px;display:block;margin-top:8px}
  .two{grid-template-columns:1fr 1fr}
  @media(max-width:900px){.two{grid-template-columns:1fr}}
  .jobsempty{color:var(--muted);font-size:13px}
  /* per-panel close. Absolutely positioned so it never becomes a grid cell. */
  [data-panel]{position:relative}
  /* These are <button> so they are reachable by keyboard. A button brings UA
     styling with it — an outset border, buttonface background, its own font,
     and 1px 6px of padding which (with the global border-box) squeezed the
     glyph into a 9px content box. Reset it all, or the hover states render as
     a red circle inside a grey 3D ring. */
  .pclose,.pdrag{appearance:none;-webkit-appearance:none;background:none;border:0;padding:0;
    margin:0;font-family:inherit;font-weight:400;display:flex;align-items:center;
    justify-content:center}
  .pclose{position:absolute;top:7px;right:9px;width:21px;height:21px;line-height:1;
    text-align:center;border-radius:50%;color:var(--muted);cursor:pointer;font-size:12px;
    opacity:0;transition:opacity .12s,background .12s,color .12s;z-index:4;user-select:none}
  [data-panel]:hover>.pclose{opacity:.75}
  .pclose:hover,.pclose:focus{background:var(--bad);color:#fff;opacity:1!important}
  .pdrag{position:absolute;top:7px;right:34px;width:21px;height:21px;line-height:1;
    text-align:center;border-radius:5px;color:var(--muted);cursor:grab;font-size:13px;
    opacity:0;transition:opacity .12s,background .12s;z-index:4;user-select:none}
  [data-panel]:hover>.pdrag{opacity:.55}
  .pdrag:hover,.pdrag:focus{opacity:1!important;background:var(--panel2)}
  .pdrag:active{cursor:grabbing}
  /* :focus, NOT :focus-visible. A keyboard user cannot hover, so a control that
     is invisible until hover must appear on ANY focus — :focus-visible only
     matches keyboard-modality focus, which would leave it invisible in the
     cases it is reached some other way. The outline ring still uses
     :focus-visible; only the reveal is broadened. */
  .pclose:focus,.pdrag:focus{opacity:1!important}
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
<a class="skiplink" href="#content">Skip to content</a>
<header>
  <h1>Storage Spaces Dashboard</h1>
  <span class="hostchip" title="Server this dashboard is reading">__HOST__</span>
  <span id="filterChip" style="display:none"></span>
  <span style="flex:1"></span>
  <a id="bundleBtn" class="themebtn" href="/api/bundle" download
     title="Download everything this dashboard knows as one JSON file"
     aria-label="Download diagnostic bundle" style="text-decoration:none">⤓</a>
  <button type="button" id="themeBtn" class="themebtn" title="Switch light / dark theme"
    aria-label="Switch light or dark theme">◐</button>
  <button type="button" id="tempUnit" class="status" title="Switch temperature units"
    aria-label="Switch temperature units" style="cursor:pointer;user-select:none;background:none;
    color:var(--muted);font-family:inherit;font-size:12px;
    border:1px solid var(--border);border-radius:12px;padding:2px 10px">°C</button>
  <span id="feeds" class="status mono"></span>
  <span id="clock" class="status mono"></span>
  <span id="conn" class="status"></span>
</header>

<div class="shell">
<!-- Icons are inline SVG, not emoji. Emoji render as a different picture on
     every platform, sit on their own baseline, and - the reason that actually
     matters here - cannot be recoloured, so they can never reflect state.
     stroke="currentColor" means an alerting section's icon goes red WITH its
     label, for free. -->
<svg width="0" height="0" style="position:absolute" aria-hidden="true"><defs>
  <g id="i-overview"><rect x="2.5" y="2.5" width="7" height="7" rx="1.5"/><rect x="12.5" y="2.5" width="7" height="5" rx="1.5"/><rect x="12.5" y="10.5" width="7" height="9" rx="1.5"/><rect x="2.5" y="12.5" width="7" height="7" rx="1.5"/></g>
  <g id="i-drives"><rect x="2.5" y="4.5" width="17" height="6" rx="2"/><rect x="2.5" y="12.5" width="17" height="6" rx="2"/><path d="M6 7.5h.01M6 15.5h.01"/></g>
  <g id="i-cache"><path d="M12 2.5 5.5 12.5h5l-1 8 7-10.5h-5z" stroke-linejoin="round"/></g>
  <g id="i-capacity"><path d="M3 6.5 12 2.5l9 4v11l-9 4-9-4z" stroke-linejoin="round"/><path d="M3 6.5 12 10.5l9-4M12 10.5v11"/></g>
  <g id="i-resiliency"><path d="M12 2.5 4.5 5.5v6c0 4.5 3.1 8.2 7.5 10 4.4-1.8 7.5-5.5 7.5-10v-6z" stroke-linejoin="round"/></g>
  <g id="i-jobs"><circle cx="12" cy="12" r="3.2"/><path d="M12 2.5v3.3M12 18.2v3.3M2.5 12h3.3M18.2 12h3.3M5.2 5.2l2.4 2.4M16.4 16.4l2.4 2.4M18.8 5.2l-2.4 2.4M7.6 16.4l-2.4 2.4"/></g>
  <g id="i-restore"><path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1" stroke-linecap="round"/><path d="M3 3.5v5h5" stroke-linejoin="round"/></g>
  <g id="i-triage"><path d="M2.5 12.5h4l2.5-6 4 12 2.5-6h6" stroke-linecap="round" stroke-linejoin="round"/></g>
</defs></svg>

<nav class="side" id="nav" aria-label="Sections">
  <div class="navsec" id="triageSec" style="display:none">Attention</div>
  <button type="button" class="navitem" id="navTriage" data-group="triage" style="display:none"><svg class="nicon" viewBox="0 0 24 24"><use href="#i-triage"/></svg>Triage <span class="ndot" id="ndTriage"></span><span class="nb" id="nbTriage"></span></button>
  <div class="navsec">Live</div>
  <button type="button" class="navitem active" data-group="overview"><svg class="nicon" viewBox="0 0 24 24"><use href="#i-overview"/></svg>Overview</button>
  <button type="button" class="navitem" data-group="drives"><svg class="nicon" viewBox="0 0 24 24"><use href="#i-drives"/></svg>Drives <span class="ndot" id="ndDrives"></span><span class="nb" id="nbDrives"></span></button>
  <button type="button" class="navitem" data-group="cache"><svg class="nicon" viewBox="0 0 24 24"><use href="#i-cache"/></svg>Cache</button>
  <div class="navsec">Configuration</div>
  <button type="button" class="navitem" data-group="capacity"><svg class="nicon" viewBox="0 0 24 24"><use href="#i-capacity"/></svg>Capacity <span class="ndot" id="ndCap"></span><span class="nb" id="nbCap"></span></button>
  <button type="button" class="navitem" data-group="resiliency"><svg class="nicon" viewBox="0 0 24 24"><use href="#i-resiliency"/></svg>Resiliency <span class="ndot" id="ndRes"></span></button>
  <button type="button" class="navitem" data-group="jobs"><svg class="nicon" viewBox="0 0 24 24"><use href="#i-jobs"/></svg>Jobs <span class="nb" id="nbJobs"></span></button>
  <div class="navsec" id="restoreSec" style="display:none">Hidden panels</div>
  <button type="button" class="navitem" id="restorePanels" style="display:none" title="Show every hidden panel again"><svg class="nicon" viewBox="0 0 24 24"><use href="#i-restore"/></svg>Restore all <span class="nb" id="nbHidden"></span></button>
</nav>
<main class="wrap" id="content">

<!-- ============================ TRIAGE ====================================
     The front door that never existed. Every other section is CURATED - you
     arrange it once and stare at it for a year. That model is right for a
     boring Tuesday and hostile at 2am, because it greets an emergency with the
     layout you built when nothing was wrong, and a panel you closed six months
     ago because it was noisy on a healthy system is not hidden, it is GONE.

     This section is COMPUTED, never curated: no data-panel attributes, so it
     cannot be closed, reordered, or lost. It answers three questions in a fixed
     order - is anything wrong, which object, and what is being done about it -
     and it is empty when the answer is "nothing", which is itself the answer.
     ======================================================================== -->
<section data-group="triage">
  <div class="card" style="border-color:var(--border)">
    <h2>Triage</h2>
    <div id="triageBody"><span class="muted">Waiting for the first topology scan…</span></div>
  </div>
  <!-- Ordering is causality. The state panels above say what is wrong NOW; this
       says what happened FIRST, which is usually the actual question. Recorded
       server-side so it survives the reload you do when something breaks. -->
  <div class="card" style="border-color:var(--border);margin-top:16px">
    <h2>What happened</h2>
    <div id="timelineBody"><span class="muted">No state changes recorded since the dashboard started.</span></div>
  </div>
</section>

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
    <h2>Throughput — live, last ~2 min</h2>
    <div class="pbody" data-pk="spark" style="height:110px;overflow:hidden">
      <canvas id="spark"></canvas>
    </div>
    <div class="status" style="margin-top:6px">
      <span class="dot" style="background:var(--read)"></span>Read
      <span class="dot" style="background:var(--write);margin-left:12px"></span>Write
    </div>
  </div>

  <!-- The same throughput, zoomed out to 15 minutes, RECORDED SERVER-SIDE so it
       is populated the instant you load the page mid-incident. It sits directly
       under the live 2-min chart, as its companion, rather than as a giant blank
       box at the top of Overview — on a calm system it is just the flat line the
       live chart already shows, only longer. Lives on Overview and not under
       Triage (which hides when nothing is wrong) so you have seen it before the
       emergency, but framed as context, not the headline. -->
  <div class="card sec" data-panel="history">
    <h2>Throughput — recorded, last 15 min <span class="muted" style="text-transform:none;letter-spacing:0">· what led up to now, kept on the server</span></h2>
    <div class="pbody" data-pk="hist" style="height:150px;overflow:hidden">
      <canvas id="histChart"></canvas>
    </div>
    <div id="histSub" class="status" style="margin-top:6px">loading…</div>
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

  <!-- The last mile. Everything else tells you WHICH drive; this is the only
       thing that tells you which drawer to open. It belongs with the Drives, and
       it must be reachable when NOTHING is wrong — you fill it in on a quiet
       afternoon, which is the one time the Triage section does not exist. -->
  <div class="card sec" data-panel="bayMap">
    <h2>Physical bay map <span class="muted" style="text-transform:none;letter-spacing:0">· which drawer to open</span></h2>
    <div id="bayHint" class="status" style="margin-bottom:10px"></div>
    <div style="overflow-x:auto"><table id="bayTbl">
      <thead><tr><th>Drive</th><th>Media</th><th style="width:34%">Bay / physical location</th>
        <th>Serial</th><th>Reported by hardware</th></tr></thead>
      <tbody><tr><td colspan="5" class="muted">Waiting for the first topology scan…</td></tr></tbody>
    </table></div>
  </div>

</section>

<section data-group="capacity" hidden>
  <div class="grid kpis" id="poolKpis" data-panel="poolStats"></div>

  <div class="card sec" data-panel="forecast">
    <h2>Capacity forecast <span class="muted" style="text-transform:none;letter-spacing:0">· days to full</span></h2>
    <div id="forecastBody"><span class="muted">Needs a few minutes of allocation history before it can say anything.</span></div>
  </div>

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
const esc = s => String(s??'').replace(/[&<>"']/g,
  c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function healthDot(h){ return `<span class="dot" style="background:${healthColor(h)}"></span>${esc(h)||'–'}`; }

// ---- OperationalStatus ------------------------------------------------------
// A DIFFERENT FIELD from HealthStatus, and the one that actually names the
// failure. HealthStatus only ever holds Healthy/Warning/Unhealthy/Unknown —
// "Degraded" and "Incomplete" are OperationalStatus values, so isWarnHealth's
// /degrad|incomplete/ could never match: it was hunting the one field that
// cannot contain the word. Meanwhile opStatus HAS been on the wire for physical
// disks, pools and virtual disks the whole time, and nothing ever read it.
//
// Severity is a TABLE, not a regex. A regex is how "Unhealthy" once matched
// /healthy/ and painted failing drives green (see the gotchas file).
// Completed against Microsoft's published state tables (learn.microsoft.com,
// "Storage Spaces and Storage Spaces Direct health and operational states").
// The hand-written version was missing six, including 'no redundancy' — which
// means DATA HAS BEEN LOST and is the single worst string Windows can return.
const OP_SEVERITY = {
  'ok':'ok', 'online':'ok', 'active':'ok', 'completed':'ok', 'no error':'ok',
  // deliberate operator actions and transient housekeeping — these must NOT
  // alarm, or red stops meaning anything
  'in maintenance mode':'info', 'starting maintenance mode':'info',
  'stopping maintenance mode':'info', 'removing from pool':'info',
  'in service':'info', 'servicing':'info', 'initializing':'info',
  'updating firmware':'info', 'starting':'info',
  // healthy, but there is an action worth taking (Optimize-StoragePool)
  'suboptimal':'info',
  // resiliency is reduced or going; the data is still reachable
  'degraded':'warn', 'incomplete':'warn', 'predictive failure':'warn',
  'stale metadata':'warn', 'unrecognized metadata':'warn',
  'abnormal latency':'warn', 'transient error':'warn', 'io error':'warn',
  'read-only':'warn', 'readonly':'warn',
  // it is not answering, or the data is gone
  'no redundancy':'bad',            // "lost data because too many drives failed"
  'lost communication':'bad', 'not responding':'bad',
  'detached':'bad', 'split':'bad', 'failed media':'bad', 'no media':'bad',
  'not usable':'bad', 'device hardware failure':'bad',
  'unrecoverable error':'bad', 'failed':'bad'
};
// The REASON codes. "Read-only" and "Detached" are states; these say why, and
// the why is the difference between an administrator's decision and a disaster.
const REASON_SEVERITY = {
  'policy':'info', 'by policy':'info', 'none':'ok', 'starting':'info',
  'incomplete':'bad',                 // pool lost quorum / not enough drives
  'majority disks unhealthy':'bad',
  'timeout':'warn'
};
function reasonSev(s){
  const k=String(s||'').trim().toLowerCase();
  if(!k || k==='none') return null;
  return REASON_SEVERITY[k] || 'warn';
}
const OP_RANK = { ok:0, info:1, unknown:2, warn:3, bad:4 };

// ---- what to DO about it ----------------------------------------------------
// A diagnosis without an action is half a triage tool. Microsoft publishes an
// explicit remedy per state, so this is mostly transcription — see
// learn.microsoft.com "Storage Spaces and Storage Spaces Direct health and
// operational states".
//
// Commands are shown for you to copy, never executed. This dashboard reads the
// storage stack; it does not repair it, and a button that silently ran
// Reset-PhysicalDisk would be the worst idea in the whole project.
const DOC_STATES = 'https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/storage-spaces-states';
const DOC_REFS   = 'https://learn.microsoft.com/en-us/windows-server/storage/refs/integrity-streams';
const DOC_TSHOOT = 'https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/troubleshooting-storage-spaces';

// Keyed by the OperationalStatus string. n = the object's name.
const FIX_BY_STATE = {
  'suboptimal':            { cmd:n=>`Optimize-StoragePool -FriendlyName '${n}'` },
  'degraded':              { cmd:n=>`Repair-VirtualDisk -FriendlyName '${n}'` },
  'incomplete':            { cmd:n=>`Repair-VirtualDisk -FriendlyName '${n}'` },
  'in maintenance mode':   { cmd:n=>`Disable-StorageMaintenanceMode -PhysicalDisk (Get-PhysicalDisk -FriendlyName '${n}')` },
  'io error':              { cmd:n=>`Reset-PhysicalDisk -FriendlyName '${n}'   # then: Repair-VirtualDisk` },
  'transient error':       { cmd:n=>`Reset-PhysicalDisk -FriendlyName '${n}'   # then: Repair-VirtualDisk` },
  'stale metadata':        { cmd:n=>`Repair-VirtualDisk -FriendlyName <space>  # if it persists: Reset-PhysicalDisk -FriendlyName '${n}'` },
  'unrecognized metadata': { cmd:n=>`Reset-PhysicalDisk -FriendlyName '${n}'   # wipes it, then adds it back to the pool` },
  'split':                 { cmd:n=>`Reset-PhysicalDisk -FriendlyName '${n}'   # then: Repair-VirtualDisk` },
  'predictive failure':    { note:'Replace the drive.' },
  'failed media':          { note:'Replace the drive.' },
  'device hardware failure':{ note:'Replace the drive.' },
  'abnormal latency':      { note:'Replace the drive if it keeps happening — it slows the whole pool.' },
  'lost communication':    { note:'Reconnect or replace the drive.' },
  'no redundancy':         { note:'Data is lost. Replace the failed drives and restore from backup.' },
  'not usable':            { doc:DOC_TSHOOT }
};

// Keyed by the rule name in the finding's key, for findings that are not a
// bare OperationalStatus.
const FIX_BY_RULE = {
  'scan-stale':  { cmd:()=>`Start-ScheduledTask -TaskPath '\\Microsoft\\Windows\\Data Integrity Scan\\' -TaskName 'Data Integrity Scan'`,
                   doc:DOC_REFS },
  'scan-result': { cmd:()=>`Get-ScheduledTaskInfo -TaskPath '\\Microsoft\\Windows\\Data Integrity Scan\\' -TaskName 'Data Integrity Scan'`,
                   doc:DOC_REFS },
  'readonly':    { cmd:n=>`Get-StoragePool -FriendlyName '${n}' | Set-StoragePool -IsReadOnly $false`, doc:DOC_STATES },
  'detached':    { cmd:()=>`Get-VirtualDisk | Where-Object OperationalStatus -eq 'Detached' | Connect-VirtualDisk`, doc:DOC_STATES },
  'regen':       { cmd:n=>`Repair-VirtualDisk -FriendlyName '${n}'`, doc:DOC_STATES },
  'latency':     { note:'Compare against its mirror partners; replace it if the gap persists.' },
  'temp':        { note:'Check airflow and drive seating. This is measured against the drive’s own rated maximum.' },
  'predict':     { cmd:()=>`Get-CimInstance -Namespace root\\wmi -ClassName MSStorageDriver_FailurePredictStatus | Where-Object PredictFailure`,
                   note:'Reported by the drive firmware, not by Storage Spaces.' },
  'counter':     { note:'If the drive is genuinely gone this is expected; if not, check the cable.' },
  'cannotpool':  { doc:DOC_STATES }
};

function fixFor(item){
  const rule = String(item.key||'').split('/').pop();
  let f = FIX_BY_RULE[rule];
  if(!f && rule==='opstatus'){
    // The finding's `why` is the joined OperationalStatus list; take the worst
    // one we have a remedy for.
    const states=String(item.why||'').split('·').map(s=>s.trim().toLowerCase());
    for(const s of states){ if(FIX_BY_STATE[s]){ f=FIX_BY_STATE[s]; break; } }
  }
  if(!f && item.what==='integrity') f={ doc:DOC_REFS };
  if(!f) return null;
  return {
    cmd:  f.cmd ? f.cmd(item.name) : null,
    note: f.note || null,
    doc:  f.doc || (item.what==='integrity' ? DOC_REFS : DOC_STATES)
  };
}

// navigator.clipboard is a SECURE-CONTEXT API — undefined over plain http:// to
// anything but localhost, which is exactly how this dashboard is reached from
// another machine. Same trap as crypto.subtle. execCommand is deprecated and
// works everywhere, so it is the fallback that actually matters here.
function copyText(s, btn){
  const done=ok=>{ const t=btn.textContent; btn.textContent=ok?'copied':'select it'; btn.classList.toggle('bad',!ok);
                   setTimeout(()=>{ btn.textContent=t; btn.classList.remove('bad'); },1500); };
  if(navigator.clipboard && window.isSecureContext){
    navigator.clipboard.writeText(s).then(()=>done(true),()=>done(false)); return;
  }
  try{
    const ta=document.createElement('textarea');
    ta.value=s; ta.style.position='fixed'; ta.style.opacity='0';
    document.body.appendChild(ta); ta.select();
    const ok=document.execCommand('copy');
    ta.remove(); done(ok);
  }catch(e){ done(false); }
}
// A status string we have never seen ranks ABOVE ok, so an unrecognised state is
// surfaced rather than silently assumed fine. Uncertainty is a value.
function opParse(s){
  const states = String(s||'').split(',').map(t=>t.trim()).filter(Boolean);
  let sev = 'ok';
  for(const t of states){
    const v = OP_SEVERITY[t.toLowerCase()] || 'unknown';
    if(OP_RANK[v] > OP_RANK[sev]) sev = v;
  }
  return { sev, states };
}
const opColor = sev => sev==='bad'    ? 'var(--bad)'
                     : sev==='warn'   ? 'var(--warn)'
                     : sev==='info'   ? 'var(--accent)'
                     : sev==='unknown'? 'var(--muted)' : 'var(--good)';
function opChip(s){
  const {sev,states} = opParse(s);
  if(!states.length || sev==='ok') return '';
  return `<span class="optag" style="color:${opColor(sev)}" title="OperationalStatus">${esc(states.join(' · '))}</span>`;
}
// Health AND operational status together — the two halves of "is this thing ok".
function statusCell(health, op){ return healthDot(health) + opChip(op); }
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

// ---- theme-aware chart colours ---------------------------------------------
// The chart layer used to carry 23 hardcoded rgba() literals — area fills like
// rgba(74,163,255,.13), chosen to glow over a DARK background. On a light theme
// a 13%-alpha blue over white is functionally invisible and every sparkline
// fill just disappears. They cannot be var() because canvas needs a literal.
//
// So: one table, resolved from the tokens once per theme and cached (cssVar()
// is a getComputedStyle call — far too expensive to run 23 times per 100ms
// frame). refreshThemeColors() is the only thing a theme switch has to call.
let TC = {};
function withAlpha(c, a){
  c = (c||'').trim();
  let m = c.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
  if(m){
    let h = m[1];
    if(h.length===3) h = h[0]+h[0]+h[1]+h[1]+h[2]+h[2];
    return `rgba(${parseInt(h.slice(0,2),16)},${parseInt(h.slice(2,4),16)},${parseInt(h.slice(4,6),16)},${a})`;
  }
  m = c.match(/^rgba?\(([^)]+)\)$/i);
  if(m){ const p=m[1].split(/[,\s/]+/).filter(Boolean); return `rgba(${p[0]},${p[1]},${p[2]},${a})`; }
  return c;   // unknown format: better a solid colour than nothing drawn
}
function refreshThemeColors(){
  const A = parseFloat(cssVar('--fill-a')) || .16;
  const g = k => cssVar('--'+k);
  TC = {
    a:A,
    good:g('good'), warn:g('warn'), bad:g('bad'), accent:g('accent'),
    read:g('read'), write:g('write'), muted:g('muted'), text:g('text'),
    border:g('border'), panel:g('panel'), panel2:g('panel2'),
    // area fills, per theme
    readFill:  withAlpha(g('read'),  A*0.8),
    writeFill: withAlpha(g('write'), A*0.8),
    readFillHi:  withAlpha(g('read'),  A),
    writeFillHi: withAlpha(g('write'), A),
    goodFill:  withAlpha(g('good'), A*1.1),
    warnFill:  withAlpha(g('warn'), A*1.1),
    badFill:   withAlpha(g('bad'),  A*1.1),
    accentFill:withAlpha(g('accent'),A)
  };
}
refreshThemeColors();

// ---- theme ------------------------------------------------------------------
// [data-theme] on <html> beats the OS preference; no stored value means follow
// the OS. The toggle cycles auto -> light -> dark so "just follow the system"
// stays reachable rather than being a state you can only leave.
function currentThemeMode(){ try{ return localStorage.getItem('ssdash.theme')||'auto'; }catch(e){ return 'auto'; } }
function applyTheme(mode){
  const r=document.documentElement;
  if(mode==='auto') r.removeAttribute('data-theme'); else r.setAttribute('data-theme',mode);
  try{ localStorage.setItem('ssdash.theme',mode); }catch(e){}
  const b=$('#themeBtn');
  if(b){
    b.textContent = mode==='light' ? '☀' : mode==='dark' ? '☾' : '◐';
    b.title = 'Theme: '+mode+' (click to change)';
  }
  refreshThemeColors();
  // Canvases hold baked-in colours from the previous theme until redrawn.
  diskKey=null; tierKey=null; spaceKey=null;
  if(typeof drawSpark==='function') drawSpark();
  if(lastTopoData) applyTopoDerived(lastTopoData);
}
function initTheme(){
  applyTheme(currentThemeMode());
  const b=$('#themeBtn');
  if(b) b.addEventListener('click',()=>{
    const order=['auto','light','dark'];
    applyTheme(order[(order.indexOf(currentThemeMode())+1)%order.length]);
  });
  // Follow the OS live while in auto.
  if(window.matchMedia) window.matchMedia('(prefers-color-scheme: dark)')
    .addEventListener('change',()=>{ if(currentThemeMode()==='auto') applyTheme('auto'); });
}

const colorFor = p => p>=90?TC.bad:p>=70?TC.warn:TC.good;

// latest per-disk status from /api/topology, keyed by OS disk number, merged
// into the realtime disk table so activity + status live in one view.
let topoDisks={};
// Last realtime payload, so triage can see counter failures without waiting for
// the 5s topology feed — a pulled drive shows up here first.
let lastPerfData=null;
// feed health — makes a stalled background collector visible instead of just
// leaving half the dashboard mysteriously blank.
let lastTopoAt=0, layoutState='pending', wearState='pending', poolState='pools —';

// ---- per-panel data age -----------------------------------------------------
// The header has always shown feed freshness, but you have to know to look at
// it — and during triage you are staring at ONE panel, not the header. A panel
// whose collector stalled kept rendering its last good numbers, silently, and
// stale data presented confidently is the defect this whole project keeps
// re-learning (gotchas 9, 15, 16, 17).
//
// The badge only appears once a feed is genuinely late — a badge that is always
// there is one nobody reads. Same rule as the OperationalStatus chip.
const FEED_AT = { perf:0, topo:0, system:0 };
// panel -> which collector actually produces its numbers. Anything unlisted is
// topology, which is the slow feed and therefore the conservative default.
const PANEL_FEED = {
  diskTable:'perf', throughput:'perf', tierAct:'perf', spaces:'perf', repair:'perf', jobs:'perf',
  'kpi-read':'perf', 'kpi-write':'perf', 'kpi-iops':'perf', 'kpi-iosize':'perf',
  'kpi-mix':'perf', 'kpi-split':'perf',
  fileCache:'system', writeCache:'system', tierMove:'system', 'kpi-cpu':'system', 'kpi-wbc':'system'
};
// A feed is "late" at 4x its own cadence — long enough not to fire on a normal
// slow pass, short enough to notice inside an incident.
function feedLimitMs(f){
  return f==='perf'   ? Math.max(2000, CFG.pollMs*20)
       : f==='system' ? Math.max(3000, CFG.systemMs*12)
       :                Math.max(20000, CFG.topologyMs*4);
}
function stampPanelAges(){
  const now=Date.now();
  document.querySelectorAll('[data-panel]').forEach(el=>{
    const feed = PANEL_FEED[el.dataset.panel] || 'topo';
    const at   = FEED_AT[feed] || (feed==='topo'?lastTopoAt:0);
    let badge  = el.querySelector(':scope > .agetag');
    const late = at>0 && (now-at) > feedLimitMs(feed);
    if(!late){ if(badge) badge.remove(); return; }
    if(!badge){
      badge=document.createElement('span');
      badge.className='agetag';
      el.appendChild(badge);
    }
    const secs=Math.round((now-at)/1000);
    badge.textContent = secs<60 ? (secs+'s old') : (Math.round(secs/60)+'m old');
    badge.title = `The ${feed} collector last published ${secs}s ago. These numbers are NOT live.`;
  });
}
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

  // Arrow keys move between sections without touching the mouse — the point of
  // the whole exercise is being able to drive this over laggy RDP at 2am.
  $('#nav').addEventListener('keydown',e=>{
    if(!['ArrowDown','ArrowUp','Home','End'].includes(e.key)) return;
    const items=[...document.querySelectorAll('#nav .navitem')].filter(n=>n.offsetParent!==null);
    const i=items.indexOf(document.activeElement);
    if(i<0) return;
    e.preventDefault();
    const j = e.key==='Home' ? 0
            : e.key==='End'  ? items.length-1
            : e.key==='ArrowDown' ? (i+1)%items.length
            : (i-1+items.length)%items.length;
    items[j].focus();
  });

  // Rows that filter the dashboard are activatable from the keyboard. Delegated,
  // so rows re-created by a render keep working without re-wiring.
  document.addEventListener('keydown',e=>{
    if(e.key!=='Enter' && e.key!==' ') return;
    const tr=e.target.closest && e.target.closest('tr[data-ft]');
    if(!tr) return;
    e.preventDefault();
    tr.click();
  });

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
  const b=document.createElement('button');       // was a <span>: unreachable by keyboard
  b.type='button';
  b.className='pclose'; b.textContent='✕';
  b.title='Hide this panel';
  b.setAttribute('aria-label','Hide the '+(el.dataset.panel||'')+' panel');
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
      const h=document.createElement('button');    // was a <span>
      h.type='button';
      h.className='pdrag'; h.textContent='⠿'; h.title='Drag to reorder';
      h.setAttribute('aria-label','Reorder the '+(el.dataset.panel||'')+' panel');
      // Keyboard equivalent of a drag: move the panel within its container.
      h.addEventListener('keydown',e=>{
        const p=el.parentElement; if(!p) return;
        if(e.key==='ArrowUp'||e.key==='ArrowLeft'){
          const prev=el.previousElementSibling;
          if(prev){ p.insertBefore(el,prev); saveOrder(); h.focus(); } e.preventDefault();
        } else if(e.key==='ArrowDown'||e.key==='ArrowRight'){
          const next=el.nextElementSibling;
          if(next){ p.insertBefore(next,el); saveOrder(); h.focus(); } e.preventDefault();
        }
      });
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
  set('#kReadSpark',  {title:'Total Read',       unit:'MB/s', scale:MBs, series:[{data:histR,color:R,fill:TC.readFillHi,label:'Read'}]});
  set('#kWriteSpark', {title:'Total Write',      unit:'MB/s', scale:MBs, series:[{data:histW,color:W,fill:TC.writeFillHi,label:'Write'}]});
  set('#kIopsSpark',  {title:'Total IOPS',       unit:'IOPS',            series:[{data:histI,color:A,fill:TC.readFillHi,label:''}]});
  set('#spark',       {title:'Total Throughput — all pool media', unit:'MB/s', scale:MBs, series:[
    {data:histR,color:R,fill:TC.readFill,label:'Read'},
    {data:histW,color:W,fill:TC.writeFill,label:'Write'}]});
  set('#kIoSizeSpark', {title:'Average I/O size', unit:'KB', scale:1/1024, series:[
    {data:histRSz,color:R,label:'Read'},{data:histWSz,color:W,label:'Write'}]});
  set('#kMixSpark',    {title:'Read / write balance', unit:'%', max:100, signed:true,
    fmtLabel:v=>Math.abs(v)<0.5?'even':(Math.abs(v).toFixed(0)+'% '+(v>0?'read':'write')),
    series:[{data:histMix,color:cssVar('--muted'),
      fill:TC.accentFill, fillNeg:TC.writeFillHi, label:'Read bias'}]});
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
  const repaint=()=>{ if(typeof drawSpark==='function') drawSpark(); };

  // The browser's native CSS `resize` grip is drawn in the bottom-right corner —
  // exactly where a full-bleed canvas paints over it, and it is clipped by the
  // chart panels' overflow:hidden. So it was "on" but invisible. Replace it with
  // an explicit handle that is always visible, works over the canvas, and drives
  // the repaint that made the old version look broken even when it did resize.
  all().forEach(el=>{
    // Grip is the pbody's next sibling, not a child: a normal-flow bar below the
    // body cannot overlap a scrolling table's rows or a chart's canvas.
    if(el.nextElementSibling && el.nextElementSibling.classList.contains('reszgrip')) return;
    const grip=document.createElement('div');
    grip.className='reszgrip';
    grip.title='Drag to resize';
    grip.setAttribute('aria-hidden','true');
    el.parentNode.insertBefore(grip, el.nextSibling);
    let startY=0, startH=0, raf=0;
    const onMove=e=>{
      const h=Math.max(70, startH + ((e.touches?e.touches[0].clientY:e.clientY) - startY));
      el.style.height=h+'px';
      if(!raf) raf=requestAnimationFrame(()=>{ raf=0; repaint(); });
    };
    const onUp=()=>{
      document.removeEventListener('pointermove',onMove);
      document.removeEventListener('pointerup',onUp);
      save(); repaint();
    };
    grip.addEventListener('pointerdown',e=>{
      e.preventDefault();
      startY=e.clientY; startH=el.getBoundingClientRect().height;
      document.addEventListener('pointermove',onMove);
      document.addEventListener('pointerup',onUp);
    });
  });

  window.addEventListener('beforeunload', save);
  window.addEventListener('resize', repaint);
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
    // Filter targets are built by several different renders, so stamp
    // focusability here rather than in six template literals that would each
    // have to remember. Idempotent, and survives an innerHTML rewrite.
    if(!el.hasAttribute('tabindex')){
      el.setAttribute('tabindex','0');
      el.setAttribute('role','button');
    }
    el.setAttribute('aria-pressed', on?'true':'false');
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
// Repaints the full-size charts. Called after a theme switch, after a section is
// shown, and after a layout change — anything that leaves a canvas holding stale
// pixels or none at all. The history chart is included because it is only
// otherwise refreshed once a minute, so a theme switch or a first reveal would
// leave it blank or in the old palette until the next poll.
function drawSpark(){
  const cv=$('#spark'); if(cv&&cv._spec) drawChart(cv,cv._spec);
  const hc=$('#histChart'); if(hc&&hc._spec&&visible(hc)) drawChart(hc,hc._spec);
}

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
// ---- peer-relative latency --------------------------------------------------
// A drive that is DYING is usually slow long before it is unhealthy. Windows
// will report HealthStatus: Healthy the entire time — there is no per-drive
// "you are slower than you should be" signal anywhere in the storage stack.
//
// But a mirror or a parity set makes every member do near-identical work, so
// the members ARE each other's control group. A drive running several times its
// tier's median latency while the tier is busy is the single best pre-failure
// signal available from data this dashboard already collects.
//
// Gating matters more than the maths. At idle, latencies are microseconds and
// ratios are pure noise, so an ungated version would cry wolf on a quiet
// Tuesday and get ignored — exactly the failure mode we designed the triage
// severity table to avoid.
const LAT_FLOOR_MS = 2.0;   // below this, a ratio is meaningless
const LAT_OUTLIER  = 2.5;   // x median before we say anything
const LAT_MIN_BUSY = 5;     // % — the tier must actually be doing work
const LAT_MIN_PEERS= 3;     // need a real median, not a coin flip
let latOutliers={};

function peerLatency(disks){
  const byTier={};
  disks.filter(x=>isPoolMedia(x) && x.countersOk!==false).forEach(x=>{
    const t=tierOf(x.mediaType); if(!t) return;
    (byTier[t]||(byTier[t]=[])).push(x);
  });
  const out={};
  for(const t in byTier){
    const peers=byTier[t];
    if(peers.length<LAT_MIN_PEERS) continue;
    const worstLat=x=>{ const h=diskHist(x.diskNumber);
      return Math.max(avgLast(h.rlat,MAXH), avgLast(h.wlat,MAXH)); };   // full window, not 500ms
    const busyOf =x=>avgLast(diskHist(x.diskNumber).busy,MAXH);
    const vals=peers.map(worstLat).filter(v=>v>0).sort((a,b)=>a-b);
    if(vals.length<LAT_MIN_PEERS) continue;
    const med=vals[Math.floor(vals.length/2)];
    if(!(med>0)) continue;
    const tierBusy=peers.reduce((a,x)=>a+busyOf(x),0)/peers.length;
    if(tierBusy<LAT_MIN_BUSY) continue;      // quiet tier: say nothing
    peers.forEach(x=>{
      const v=worstLat(x);
      if(v>=LAT_FLOOR_MS && v/med>=LAT_OUTLIER)
        out[String(x.diskNumber)]={ratio:v/med, ms:v, med, tier:t, name:x.name};
    });
  }
  return out;
}

function diskHist(dn){ const k=String(dn);
  return dHist[k]||(dHist[k]={busy:[],read:[],write:[],iops:[],queue:[],rlat:[],wlat:[]}); }
const busyFill = p => p>=90?TC.badFill:p>=70?TC.warnFill:TC.goodFill;

// A failed drive stops having a PhysicalDisk counter instance. The sampler
// rebuilds its counter table every 120s from GetInstanceNames(), and after that
// rebuild the dead drive is simply not in the perf feed any more — so its row
// VANISHED from the table. The single most alarming event on the system made
// the evidence disappear, which is gotcha #9 in its purest form.
//
// The topology feed still knows about it (that is where "Lost Communication"
// comes from). So the table is the UNION of what the counters report and what
// the storage stack knows exists. A drive present in topology but missing from
// perf is rendered as absent, not omitted.
function withAbsentDrives(perfDisks){
  const have=new Set(perfDisks.map(x=>String(x.diskNumber)));
  const extra=[];
  for(const k in topoDisks){
    if(have.has(k)) continue;
    const t=topoDisks[k]; if(!t) continue;
    // same membership test filterDisks() uses, so an absent drive respects the
    // active pool/space filter instead of leaking into a filtered view
    if(filter){ const s=(filterSets[filter.type]||{})[filter.key]; if(s && !s.has(String(k))) continue; }
    extra.push({
      diskNumber:k, instance:'', name:t.name||('Disk '+k),
      mediaType:t.mediaType||'Unknown', kind:'physical',
      health:t.health||'', busType:t.busType||'', isSystem:false,
      countersOk:false, absent:true, busy:null,
      readBps:0, writeBps:0, reads:0, writes:0, queue:0,
      readLatencyMs:0, writeLatencyMs:0
    });
  }
  return extra.length ? perfDisks.concat(extra) : perfDisks;
}

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
    // countersOk===false means this drive's perf counter instance stopped
    // answering — which is what a PULLED DRIVE looks like for up to 120s, until
    // the sampler rebuilds. Do NOT record it as history: zeros would read as an
    // idle drive and the old 100-minus-idle arithmetic read as a pegged one.
    const ctrDead = x.countersOk===false;
    if(!ctrDead){
      push(h.busy,x.busy); push(h.read,x.readBps); push(h.write,x.writeBps);
      push(h.iops,x.reads+x.writes); push(h.queue,x.queue);
      push(h.rlat,x.readLatencyMs); push(h.wlat,x.writeLatencyMs);
    }
    const st=topoDisks[String(x.diskNumber)], sb=avgLast(h.busy);

    const top=e.tr.offsetTop, vis=shown && (top+e.tr.offsetHeight)>vTop && top<vBot;
    // graphs carry the full-resolution signal
    // Specs are always attached (cheap, and keeps every graph zoomable even
    // before it has been painted); only the drawing is skipped when off-screen.
    const who=`${x.name} · #${x.diskNumber}`;
    setSpec(e.busyc,{title:who+' — Busy', unit:'%', max:100,
      series:[{data:h.busy,color:colorFor(sb),fill:busyFill(sb),label:'Busy'}]});
    setSpec(e.thruc,{title:who+' — Throughput', unit:'MB/s', scale:MBs, series:[
      {data:h.read,color:rc,fill:TC.readFill,label:'Read'},
      {data:h.write,color:wc,fill:TC.writeFill,label:'Write'}]});
    if(vis){
      drawMini(e.busyc,[{data:h.busy,color:colorFor(sb),fill:busyFill(sb)}],100);
      drawMini(e.thruc,[{data:h.read,color:rc},{data:h.write,color:wc}]);
    }
    // numbers are smoothed so they're actually readable
    if(ctrDead){
      // "?" — never 0 (reads as calm) and never 100 (reads as on fire).
      const q='<span class="unkval">?</span>';
      e.busyv.innerHTML=q; e.busyv.style.color='';
      e.thruv.innerHTML=q; e.iops.innerHTML=q; e.queue.innerHTML=q; e.lat.innerHTML=q;
      e.tr.title = x.absent
        ? 'This drive has NO performance counter instance at all — the storage stack '
         +'still lists it, but Windows is no longer collecting I/O for it. That is what '
         +'a pulled or dead drive looks like once the sampler has rebuilt its counter table.'
        : 'No counter data for this drive — the performance counter instance '
         +'stopped responding. A pulled or failed drive looks exactly like this '
         +'until the sampler rebuilds (up to 120s).';
      e.tr.classList.toggle('absent', !!x.absent);
    } else {
      e.busyv.textContent=sb.toFixed(0)+'%'; e.busyv.style.color=busyColor(sb);
      e.thruv.textContent=mbps(avgLast(h.read)).toFixed(1)+' / '+mbps(avgLast(h.write)).toFixed(1);
      e.iops.textContent=num(avgLast(h.iops));
      e.queue.textContent=avgLast(h.queue).toFixed(2);
      e.lat.textContent=avgLast(h.rlat).toFixed(1)+'/'+avgLast(h.wlat).toFixed(1);
      if(e.tr.title) e.tr.title='';
      e.tr.classList.remove('absent');
    }

    // slow-changing cells: only touch the DOM when the value actually changes
    const bt=(st&&st.busType)||x.busType||'';
    // The bay goes in the SUBTITLE, not a new column: it is the thing you read
    // last (once you already know which drive), and it must be next to the
    // drive's name rather than eleven columns away at 2am.
    const bay=(st&&st.bay)||'';
    const sub='#'+x.diskNumber+(bt?(' · '+bt):'')
      +(bay?(' · '+bay):'')
      +(x.kind==='virtual'?' · space':'')+(x.isSystem?' · system':'');
    const usage=st?st.usage:'–', size=st?fmtBytes(st.size):'–';
    const wear=st?((st.wear==null?'–':st.wear+'%')+' / '+tempStr(st.tempC)):'–';
    const hv=x.health||(st?st.health:'');
    // OperationalStatus: the field that actually names the failure. Shipped by
    // the collector since day one, rendered here for the first time.
    const ov=(st&&st.opStatus)||'';
    const lo=latOutliers[String(x.diskNumber)];
    const hk=hv+' '+ov+(ctrDead?' !':'')+(x.absent?' X':'')+' '+usage
             +(lo?(' L'+lo.ratio.toFixed(1)):'');
    if(e._name!==x.name){ e.name.textContent=x.name; e._name=x.name; }
    if(e._sub!==sub){ e.sub.textContent=sub; e._sub=sub; }
    if(e._type!==x.mediaType){ e.type.innerHTML=typeTag(x.mediaType); e._type=x.mediaType; }
    if(e._usage!==usage){ e.usage.textContent=usage; e._usage=usage; }
    if(e._size!==size){ e.size.textContent=size; e._size=size; }
    if(e._wear!==wear){ e.wear.textContent=wear; e._wear=wear; }
    if(e._health!==hk){
      e.health.innerHTML=statusCell(hv,ov)
        +(x.absent
            ? '<span class="optag" style="color:var(--bad)" title="No performance counter instance exists for this drive">not reporting</span>'
            : ctrDead
              ? '<span class="optag" style="color:var(--muted)" title="Performance counter instance is not responding">no counter</span>'
              : '')
        // Usage is how a hot spare, a retired drive or a journal disk announces
        // itself. Auto-Select is the normal case and is not worth a chip.
        + (usage && !/^auto[- ]?select$/i.test(usage) && usage!=='–'
            ? `<span class="optag" style="color:${/retired/i.test(usage)?'var(--warn)':'var(--accent)'}" title="PhysicalDisk Usage">${esc(usage)}</span>`
            : '')
        + (lo
            ? `<span class="optag" style="color:var(--warn)" title="${lo.ms.toFixed(1)}ms vs a ${lo.tier} tier median of ${lo.med.toFixed(1)}ms. Windows will keep calling this drive Healthy.">${lo.ratio.toFixed(1)}x tier latency</span>`
            : '');
      e._health=hk;
    }
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
    markActive();   // these rows are filter targets; re-stamp focusability
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
      {data:h.read,color:rc,fill:TC.readFill,label:'Read'},
      {data:h.write,color:wc,fill:TC.writeFill,label:'Write'}]});
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
        <span><b>${p.name}</b> <span class="muted">${(p.diskNumbers||[]).length} drives · ${statusCell(p.health,p.opStatus)}</span></span>
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
// ---- triage rule registry ---------------------------------------------------
// Each rule owns ONE concern and returns findings — {sev, what, name, why,
// detail, rule} — for a context {pd, pools, vds, jobs, d, perf, lat}. This used
// to be a 100-line wall of forEach/if inside renderTriage; as a registry each
// concern is isolated, independently testable, and a new signal is a new entry
// instead of a deeper function. A rule that throws is skipped, not fatal — one
// broken signal must never blank the whole triage view.
const TRIAGE_RULES = [
  {
    id:'health-opstatus',
    // The core: HealthStatus + OperationalStatus across every object. The field
    // that names the failure (opStatus) went unread for the life of the project.
    run:({pd,pools,vds})=>{
      const out=[];
      const scan=(list,what)=>list.forEach(o=>{
        const op=opParse(o.opStatus);
        const hBad=isBadHealth(o.health), hWarn=isWarnHealth(o.health);
        const sev = (op.sev==='bad'||hBad) ? 'bad'
                  : (op.sev==='warn'||hWarn) ? 'warn'
                  : (op.sev==='info') ? 'info'
                  : (op.sev==='unknown') ? 'unknown' : null;
        if(!sev) return;
        out.push({ sev, what, name:o.name||('#'+(o.number!=null?o.number:'?')),
          why: op.states.filter(s=>s.toLowerCase()!=='ok').join(' · ') || o.health || 'unknown state',
          detail: o.health && o.health!=='Healthy' ? ('health: '+o.health) : '', rule:'opstatus' });
      });
      scan(pd,'drive'); scan(pools,'pool'); scan(vds,'space');
      return out;
    }
  },
  {
    id:'pool-readonly',
    // Read-only because the pool LOST QUORUM is a catastrophe; read-only because
    // an admin set it is a Tuesday. Both used to render as the bare word.
    run:({pools})=>pools.filter(p=>p.isReadOnly||reasonSev(p.readOnlyReason)).map(p=>{
      const sev=reasonSev(p.readOnlyReason);
      return { sev: sev==='bad'?'bad':sev==='info'?'info':'warn', what:'pool', name:p.name,
        why:'read-only'+(p.readOnlyReason&&p.readOnlyReason!=='None'?(' — '+p.readOnlyReason):''),
        detail: /incomplete/i.test(p.readOnlyReason||'') ? 'the pool lost quorum: most drives are missing or offline'
          : /policy/i.test(p.readOnlyReason||'') ? 'an administrator set this; Set-StoragePool -IsReadOnly $false to clear'
          : 'no writes are possible until this clears', rule:'readonly' };
    })
  },
  {
    id:'vdisk-detached',
    run:({vds})=>vds.filter(v=>reasonSev(v.detachedReason)).map(v=>({
      sev:reasonSev(v.detachedReason), what:'space', name:v.name, why:'detached — '+v.detachedReason,
      detail: /majority/i.test(v.detachedReason) ? 'too many drives failed, are missing, or hold stale data'
        : /policy/i.test(v.detachedReason) ? 'taken offline deliberately; Connect-VirtualDisk to reattach'
        : /timeout/i.test(v.detachedReason) ? 'attaching took too long; try Disconnect- then Connect-VirtualDisk'
        : 'not enough drives are present to read it', rule:'detached' }))
  },
  {
    id:'temperature',
    // Judged against each drive's OWN rated maximum, not a fixed number — a temp
    // that alarms for a spindle is normal for an NVMe.
    run:({pd})=>{
      const out=[];
      pd.forEach(p=>{
        if(p.tempC==null || !p.tempMaxC) return;
        const pct=p.tempC/p.tempMaxC;
        if(pct>=1.0) out.push({sev:'bad',what:'drive',name:p.name,
          why:Math.round(p.tempC)+'°C — at or over its rated max', detail:'rated maximum is '+Math.round(p.tempMaxC)+'°C', rule:'temp'});
        else if(pct>=0.9) out.push({sev:'warn',what:'drive',name:p.name,
          why:Math.round(p.tempC)+'°C — within 10% of its rated max', detail:'rated maximum is '+Math.round(p.tempMaxC)+'°C', rule:'temp'});
      });
      return out;
    }
  },
  {
    id:'smart-predict',
    // The drive firmware's own failure flag — distinct from Storage Spaces'
    // "Predictive Failure", and Spaces does not always surface it.
    run:({d})=>(d.smart && d.smart.failing>0) ? [{ sev:'bad', what:'smart', name:'SMART',
      why:d.smart.failing+' drive(s) predicting failure',
      detail:'reported by drive firmware, not by Storage Spaces — check Get-CimInstance -Namespace root\\wmi MSStorageDriver_FailurePredictStatus',
      rule:'predict' }] : []
  },
  {
    id:'refs-integrity',
    run:({d})=>{
      const ig=d.integrity; if(!ig) return [];
      const out=[];
      (ig.events||[]).filter(e=>/error|critical/i.test(e.level)).slice(0,5).forEach(e=>
        out.push({sev:'bad',what:'integrity',name:'ReFS',why:e.src.replace('Microsoft-Windows-','')+' event '+e.id,detail:e.msg,rule:'event'+e.id}));
      if(ig.scan){
        const lr=ig.scan.lastRun?new Date(ig.scan.lastRun):null;
        const days=lr?Math.round((Date.now()-lr.getTime())/86400000):null;
        if(days===null) out.push({sev:'warn',what:'integrity',name:'Data Integrity Scan',why:'has never run',detail:'nothing has verified file data on this machine',rule:'scan-stale'});
        else if(days>45) out.push({sev:'warn',what:'integrity',name:'Data Integrity Scan',why:'last ran '+days+' days ago',detail:'default cadence is 4 weeks',rule:'scan-stale'});
        else if(ig.scan.lastResult!==0 && ig.scan.lastResult!=null && ig.scan.lastResult!==267011)
          out.push({sev:'warn',what:'integrity',name:'Data Integrity Scan',why:'last run failed (0x'+(ig.scan.lastResult>>>0).toString(16)+')',detail:'',rule:'scan-result'});
      }
      return out;
    }
  },
  {
    id:'needs-regen',
    // Degraded data a "Healthy" rollup will not tell you about.
    run:({vds})=>vds.map(v=>{
      const n=(v.needsRegen||0)+(v.stale||0)+(v.missing||0);
      return n>0 ? {sev:'warn',what:'space',name:v.name,why:fmtBytes(n)+' needs regeneration',detail:'resiliency is reduced',rule:'regen'} : null;
    }).filter(Boolean)
  },
  {
    id:'dead-counter',
    // A drive whose perf counter stopped answering — what a pulled drive looks
    // like for up to 120s before the topology feed catches up.
    run:({perf})=>((perf&&perf.disks)||[]).filter(x=>x.countersOk===false).map(x=>({
      sev:'warn',what:'drive',name:x.name||('#'+x.diskNumber),
      why:'performance counter not responding',detail:'a pulled or failed drive looks exactly like this',rule:'counter'}))
  },
  {
    id:'peer-latency',
    // Several times slower than its own mirror partners while Windows still says
    // Healthy — the only pre-failure signal on the page.
    run:({lat})=>Object.keys(lat||{}).map(k=>{
      const o=lat[k];
      return {sev:'warn',what:'drive',name:o.name||('#'+k),why:o.ratio.toFixed(1)+'x its tier latency',
        detail:o.ms.toFixed(1)+'ms vs '+o.med.toFixed(1)+'ms median — health still reads OK',rule:'latency'};
    })
  },
  {
    id:'jobs',
    run:({jobs})=>jobs.map(j=>({sev:'info',what:'job',name:j.name||'storage job',
      why:(j.description||j.state||'running')+(j.percent!=null?(' · '+j.percent.toFixed(0)+'%'):''),detail:'',rule:'job'}))
  }
];

// ---- triage ----------------------------------------------------------------
// Computed, never curated. Runs every TRIAGE_RULE, ranks the findings worst
// first, applies per-machine severity overrides, and renders. The rules live in
// TRIAGE_RULES above; this function is now just orchestration and rendering.
function renderTriage(d, perf){
  const el=$('#triageBody'); if(!el) return;
  const pd=d.physicalDisks||[], pools=d.pools||[], vds=d.virtualDisks||[], jobs=(perf&&perf.jobs)||[];
  let items=[];
  const rank={bad:0,warn:1,info:2,unknown:3,muted:4};

  // Every finding carries a STABLE rule key so you can tell the dashboard that
  // this particular thing is not an emergency on this machine. The key is
  // deliberately (what, name, rule) and not the message text — otherwise
  // rewording a string would silently un-mute something you had dealt with.
  const add=(sev,what,name,why,detail,rule)=>{
    const key=[what,name,rule||'state'].join('/');
    const override=alertRules[key];
    items.push({
      sev: override==='hidden' ? 'hidden' : (override || sev),
      natural: sev, key, muted: !!override,
      what, name, why, detail: detail||''
    });
  };

  // Bay lookup for triage rows: knowing LAB-SSD-02 is dead is not the answer
  // when you are standing in front of the rack.
  const bayOf=n=>{ const p=pd.find(x=>x.name===n||('#'+x.number)===n); return (p&&p.bay)||''; };

  // Every rule in TRIAGE_RULES returns findings for one concern. Feed each
  // through add() so severity overrides and stable keys apply uniformly.
  const cx = { pd, pools, vds, jobs, d, perf, lat: latOutliers };
  for(const rule of TRIAGE_RULES){
    let found;
    try { found = rule.run(cx) || []; }
    catch(e){ if(window.console) console.error('triage rule "'+rule.id+'" threw:', e); continue; }
    for(const f of found) add(f.sev, f.what, f.name, f.why, f.detail, f.rule);
  }

  // Hidden items are removed from the ranked list but COUNTED. A suppressed
  // finding that leaves no trace is the exact defect this dashboard exists to
  // fix — silence that looks like reassurance. There is always a visible
  // "N suppressed" affordance and one click brings them back.
  const hiddenItems = items.filter(i=>i.sev==='hidden');
  items = items.filter(i=>i.sev!=='hidden');
  if(showSuppressed) items = items.concat(hiddenItems.map(i=>({...i, sev:'muted'})));

  const rankOf=i=>rank[i.sev]!=null?rank[i.sev]:5;
  items.sort((a,b)=>rankOf(a)-rankOf(b));

  const worst = items.length ? items[0].sev : null;
  const nd=$('#ndTriage'), nav=$('#navTriage'), sec=$('#triageSec'), nb=$('#nbTriage');
  const actionable = items.filter(i=>i.sev==='bad'||i.sev==='warn').length;
  if(nav){
    // The entry only exists when there is something to triage. An always-present
    // "Triage: all clear" is a thing you stop reading. It also appears once any
    // state has CHANGED, even if everything is healthy again — "a drive dropped
    // and came back" is exactly the thing you want to find out about later.
    const show = items.length>0 || ((d.events||[]).length>0);
    nav.style.display = show?'':'none';
    if(sec) sec.style.display = show?'':'none';
    if(nb) nb.textContent = actionable || '';
    if(nd) nd.className = 'ndot' + (worst==='bad'?' bad':worst==='warn'?' warn':'');
    nav.classList.toggle('alert', worst==='bad');
    nav.classList.toggle('warnstate', worst==='warn');
  }

  // Always visible, even when everything is clear: suppression must never be
  // invisible, or you have built the thing this project keeps deleting.
  const suppressedBar = hiddenItems.length
    ? `<div class="supbar">${hiddenItems.length} finding${hiddenItems.length===1?'':'s'} suppressed on this machine`
      + `<button type="button" id="supToggle">${showSuppressed?'hide them':'show them'}</button></div>`
    : '';

  if(!items.length){
    el.innerHTML='<div style="display:flex;align-items:center;gap:10px;padding:6px 0">'
      +'<span class="dot" style="background:var(--good)"></span>'
      +'<span>Nothing needs attention.</span>'
      +'<span class="muted">'+pd.length+' drives, '+pools.length+' pool'+(pools.length===1?'':'s')
      +', '+vds.length+' space'+(vds.length===1?'':'s')+' checked.</span></div>'
      + suppressedBar;
    wireTriageControls();
    return;
  }
  const col=s=>s==='bad'?'var(--bad)':s==='warn'?'var(--warn)':s==='unknown'?'var(--muted)'
              :s==='muted'?'var(--border)':'var(--accent)';
  el.innerHTML=items.map(i=>{
    const bay = i.what==='drive' ? bayOf(i.name) : '';
    const dn  = i.sev==='muted';
    return `<div class="trow${dn?' rmuted':''}" style="border-left:3px solid ${col(i.sev)}">
      <span class="tkind">${esc(i.what)}</span>
      <b>${esc(i.name)}</b>
      ${bay?`<span class="baytag" title="Physical location">${esc(bay)}</span>`:''}
      <span class="twhy" style="color:${col(i.sev)}">${esc(i.why)}</span>
      ${i.detail?`<span class="muted">${esc(i.detail)}</span>`:''}
      ${i.muted?`<span class="mutetag" title="Severity overridden on this machine">${dn?'suppressed':esc(i.sev)}</span>`:''}
      ${(()=>{ const f=fixFor(i); if(!f) return '';
        return `<span class="fixrow">`
          + (f.note?`<span class="fixnote">${esc(f.note)}</span>`:'')
          + (f.cmd?`<code class="fixcmd">${esc(f.cmd)}</code>`
                  +`<button type="button" class="ract fixcopy" data-cmd="${esc(f.cmd)}">copy</button>`:'')
          + (f.doc?`<a class="ract" href="${esc(f.doc)}" target="_blank" rel="noopener noreferrer">docs ↗</a>`:'')
          + `</span>`; })()}
      ${alertsEditable?`<span class="rowacts">
        ${i.muted
          ? `<button type="button" class="ract" data-rule="${esc(i.key)}" data-level="">restore</button>`
          : `<button type="button" class="ract" data-rule="${esc(i.key)}" data-level="info" title="Keep showing it, but not as a problem">not critical</button>
             <button type="button" class="ract" data-rule="${esc(i.key)}" data-level="hidden" title="Suppress it (still counted below)">suppress</button>`}
      </span>`:''}
    </div>`;
  }).join('') + suppressedBar;
  wireTriageControls();
}

// Severity overrides are per-machine judgement, stored server-side, loopback-only
// to change — the same rule as bays and identify.
function wireTriageControls(){
  const t=$('#supToggle');
  if(t) t.addEventListener('click',()=>{ showSuppressed=!showSuppressed; if(lastTopoData) renderTriage(lastTopoData,lastPerfData); });
  document.querySelectorAll('#triageBody .fixcopy').forEach(b=>{
    b.addEventListener('click',()=>copyText(b.dataset.cmd, b));
  });
  document.querySelectorAll('#triageBody .ract[data-rule]').forEach(b=>{
    b.addEventListener('click',async ()=>{
      b.disabled=true;
      try{
        const r=await fetch('/api/alerts',{method:'POST',headers:{'Content-Type':'application/json'},
          body:JSON.stringify({key:b.dataset.rule, level:b.dataset.level})});
        if(!r.ok){ b.textContent='failed'; b.title='HTTP '+r.status; b.disabled=false; return; }
        if(b.dataset.level) alertRules[b.dataset.rule]=b.dataset.level;
        else delete alertRules[b.dataset.rule];
        if(lastTopoData) renderTriage(lastTopoData,lastPerfData);
      }catch(e){ b.textContent='failed'; b.title=String(e&&e.message||e); b.disabled=false; }
    });
  });
}

// ---- event timeline ---------------------------------------------------------
// Newest first, because during an incident the last thing that happened is the
// thing you are staring at, and you read BACKWARDS to find the cause.
function renderTimeline(d){
  const el=$('#timelineBody'); if(!el) return;
  const ev=(d.events||[]).slice().reverse();
  if(!ev.length){
    el.innerHTML='<span class="muted">No state changes recorded since the dashboard started.</span>';
    return;
  }
  // Severity of a transition is the severity of where it ENDED, except a
  // disappearance which is always bad regardless of what it looked like before.
  const sevOf=e=>{
    if(e.verb==='disappeared') return 'bad';
    const parts=String(e.to||'').split('/').map(s=>s.trim());
    const op=opParse(parts[1]||'');
    if(op.sev==='bad'||isBadHealth(parts[0])) return 'bad';
    if(op.sev==='warn'||isWarnHealth(parts[0])) return 'warn';
    if(op.sev==='info') return 'info';
    return 'ok';
  };
  const col=s=>s==='bad'?'var(--bad)':s==='warn'?'var(--warn)':s==='info'?'var(--accent)':'var(--good)';
  const t0=ev.length?new Date(ev[0].t).getTime():0;
  el.innerHTML=ev.slice(0,60).map(e=>{
    const s=sevOf(e), when=new Date(e.t);
    const ago=Math.round((t0-when.getTime())/1000);
    // Seconds up to ten minutes. An incident's whole causal chain usually fits
    // inside a couple of minutes, and rounding it to whole minutes destroys the
    // ordering that is the entire point of this panel — two events five seconds
    // apart rendered as "-3m" and "-2m" and looked a minute apart.
    const rel = ago<=0 ? 'latest' : ago<600 ? ('-'+ago+'s') : ago<3600 ? ('-'+Math.round(ago/60)+'m') : ('-'+(ago/3600).toFixed(1)+'h');
    const change = e.verb==='changed'
      ? `<span class="muted">${esc(e.from)}</span> <span class="muted">→</span> <span style="color:${col(s)}">${esc(e.to)}</span>`
      : e.verb==='appeared'
        ? `<span style="color:${col(s)}">appeared as ${esc(e.to)}</span>`
        : `<span style="color:var(--bad)">disappeared</span> <span class="muted">(was ${esc(e.from)})</span>`;
    return `<div class="trow" style="border-left:3px solid ${col(s)}">
      <span class="tkind mono">${when.toLocaleTimeString()}</span>
      <span class="tkind">${esc(e.kind)}</span>
      <b>${esc(e.name)}</b>
      ${change}
      <span class="muted mono">${rel}</span>
    </div>`;
  }).join('');
}

// ---- server-recorded history ------------------------------------------------
// Fetched on load and then slowly, NOT on the realtime cadence: at 37 drives
// this payload is around a megabyte, and it exists to answer "what did the run
// up to now look like", which does not change ten times a second.
const histT=[], histTr=[], histTw=[];
let histSeeded=false;
async function pollHistory(){
  const h = await getJson('/api/history');
  if(!h) return;
  const n=(h.t||[]).length;
  histT.length=0; histTr.length=0; histTw.length=0;
  (h.totals&&h.totals.r||[]).forEach(v=>histTr.push(v));
  (h.totals&&h.totals.w||[]).forEach(v=>histTw.push(v));
  (h.t||[]).forEach(v=>histT.push(v));
  const c=$('#histChart');
  if(c){
    setSpec(c,{title:'Last 15 minutes — throughput', unit:'MB/s', scale:MBs,
      sampleMs:h.sampleMs||1000, maxPoints:900,
      series:[{data:histTr,color:TC.read, fill:TC.readFill, label:'Read'},
              {data:histTw,color:TC.write,fill:TC.writeFill,label:'Write'}]});
    // drawChart takes (canvas, SPEC). Calling it with one argument hit
    // `if(!cv||!spec||!spec.series) return;` and painted nothing — while
    // double-click still worked, because the zoom modal passes the spec
    // explicitly. A blank canvas next to a subtitle reading "174 samples"
    // is exactly the confident-but-wrong rendering this project keeps fixing.
    if(visible(c)) drawChart(c, c._spec);
  }
  const sub=$('#histSub');
  if(sub){
    if(!n){ sub.textContent='No history yet — the server has been up less than a second.'; }
    else {
      const secs=n*((h.sampleMs||1000)/1000);
      const peak=Math.max(maxOf(histTr),maxOf(histTw));
      sub.textContent = `${n} sample${n===1?'':'s'} · ${secs<60?Math.round(secs)+'s':Math.round(secs/60)+' min'} recorded · `
        + `peak ${mbps(peak).toFixed(1)} MB/s`
        + (n>=900?' · window full (oldest samples are being dropped)':'');
    }
  }
  histSeeded=true;
  renderForecast(h.capacity||{});
}

// ---- capacity forecast ------------------------------------------------------
// Least-squares fit over the allocation series. Deliberately refuses to answer
// rather than extrapolating from noise: a pool that has not moved, or has only
// a few minutes of history, gets "not enough signal" instead of a confident
// number. A wrong date here is worse than no date.
function renderForecast(cap){
  const el=$('#forecastBody'); if(!el) return;
  const names=Object.keys(cap||{});
  if(!names.length){
    el.innerHTML='<span class="muted">No pool allocation history yet.</span>';
    return;
  }
  const rows=names.map(name=>{
    const pts=(cap[name]||[]).filter(p=>p&&p.t!=null&&p.alloc!=null);
    const size=pts.length?pts[pts.length-1].size:0;
    const used=pts.length?pts[pts.length-1].alloc:0;
    const pct=size>0?(used/size*100):0;
    if(pts.length<10) return {name,size,used,pct,verdict:'not enough history yet',sev:'muted',
                              detail:pts.length+' sample(s) — needs ~10 minutes'};
    // least squares on (seconds, bytes)
    const t0=pts[0].t;
    const xs=pts.map(p=>p.t-t0), ys=pts.map(p=>p.alloc);
    const n=xs.length, sx=xs.reduce((a,b)=>a+b,0), sy=ys.reduce((a,b)=>a+b,0);
    const sxx=xs.reduce((a,b)=>a+b*b,0), sxy=xs.reduce((a,b,i)=>a+b*ys[i],0);
    const den=n*sxx-sx*sx;
    if(!den) return {name,size,used,pct,verdict:'flat',sev:'good',detail:'allocation is not changing'};
    const slope=(n*sxy-sx*sy)/den;                 // bytes per second
    const perDay=slope*86400;
    if(Math.abs(perDay) < size*0.0005)             // <0.05% of the pool per day
      return {name,size,used,pct,verdict:'stable',sev:'good',
              detail:'no meaningful growth over '+Math.round((xs[n-1])/60)+' min of history'};
    if(perDay<0)
      return {name,size,used,pct,verdict:'shrinking',sev:'good',
              detail:'freeing '+fmtBytes(-perDay)+'/day'};
    const days=(size-used)/perDay;
    const sev = days<14?'bad':days<60?'warn':'good';
    return {name,size,used,pct,sev,
            verdict:(days<1?'full in under a day':'~'+(days<30?Math.round(days):Math.round(days))+' days to full'),
            detail:'growing '+fmtBytes(perDay)+'/day · based on '+Math.round(xs[n-1]/60)+' min of history'};
  });
  const col=s=>s==='bad'?'var(--bad)':s==='warn'?'var(--warn)':s==='good'?'var(--good)':'var(--muted)';
  el.innerHTML=rows.map(r=>`<div class="trow" style="border-left:3px solid ${col(r.sev)}">
      <span class="tkind">pool</span><b>${esc(r.name)}</b>
      <span class="twhy" style="color:${col(r.sev)}">${esc(r.verdict)}</span>
      <span class="muted">${esc(r.detail)}</span>
      <span class="muted mono">${fmtBytes(r.used)} / ${fmtBytes(r.size)} · ${r.pct.toFixed(0)}%</span>
    </div>`).join('');
}

// ---- physical bay map -------------------------------------------------------
// Editable only from loopback — the server enforces it, this just reflects it.
// The whole point is knowledge a human supplies once while standing in front of
// the rack, so it is keyed on the SERIAL NUMBER: the identifier printed on the
// drive itself, which survives reboots, re-cabling, and moving the disk to a
// different port. Everything else about a drive moves (see: the entire lab).
let bayEditable=false, bayPath='', bayKey=null;
// Per-machine severity overrides for triage findings.
let alertRules={}, alertsEditable=false, alertsPath='', showSuppressed=false;
async function loadAlerts(){
  const a = await getJson('/api/alerts');
  if(!a) return;
  alertRules = a.rules || {};
  alertsEditable = !!a.editable;
  alertsPath = a.path || '';
  if(lastTopoData) renderTriage(lastTopoData, lastPerfData);
}
function bayKeyOf(p){ return (p.serial&&p.serial.trim()) || p.uniqueId || ''; }

async function loadBays(){
  const b = await getJson('/api/bays');
  if(!b) return;
  bayEditable = !!b.editable; bayPath = b.path||'';
  const hint=$('#bayHint');
  if(hint){
    hint.innerHTML = bayEditable
      ? `Editing enabled — you are on the machine itself. Saved to <span class="mono">${esc(bayPath)}</span> as you type.`
      : `<span style="color:var(--warn)">Read-only.</span> Bay labels can only be edited from the console of this machine, `
        +`not over the network. Edit <span class="mono">${esc(bayPath)}</span> directly, or open the dashboard on the box.`;
  }
}
async function saveBay(key, label, inputEl){
  try{
    const r = await fetch('/api/bays',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({key,bay:label})});
    if(!r.ok){
      // Never let a failed save look like a successful one — that is the whole
      // disease this project has been fixing all night.
      inputEl.style.borderColor='var(--bad)';
      inputEl.title='Save FAILED: HTTP '+r.status+(r.status===403?' — editing is loopback-only':'');
      return;
    }
    inputEl.style.borderColor='var(--good)';
    inputEl.title='Saved to '+bayPath;
    setTimeout(()=>{ inputEl.style.borderColor=''; },1200);
  }catch(e){
    inputEl.style.borderColor='var(--bad)';
    inputEl.title='Save failed: '+(e&&e.message||e);
  }
}

function renderBayMap(d){
  const tb=document.querySelector('#bayTbl tbody'); if(!tb) return;
  // Real pool media only: virtual disks have no drawer.
  const pd=(d.physicalDisks||[]).filter(p=>!/^space$/i.test(p.mediaType));
  if(!pd.length){ tb.innerHTML='<tr><td colspan="5" class="muted">No physical disks reported.</td></tr>'; return; }
  const key=pd.map(p=>bayKeyOf(p)).join('|');
  if(key===bayKey) return;              // don't rebuild under the user's cursor
  bayKey=key;
  tb.innerHTML=pd.map(p=>{
    const k=bayKeyOf(p);
    const hw=[p.enclosure!==''?('encl '+p.enclosure):'', p.slot!==''?('slot '+p.slot):'', p.physLoc]
             .filter(Boolean).join(' · ') || '—';
    return `<tr>
      <td><b>${esc(p.name)}</b><div class="muted mono" style="font-size:11px">#${esc(String(p.number))}</div></td>
      <td>${typeTag(p.mediaType)}</td>
      <td><input data-baykey="${esc(k)}" value="${esc(p.bay||'')}"
            placeholder="${bayEditable?'e.g. shelf 2 bay 7':'read-only'}"
            ${bayEditable?'':'disabled'} aria-label="Bay for ${esc(p.name)}"></td>
      <td class="mono muted" style="font-size:11px">${esc(p.serial||'—')}</td>
      <td class="muted" style="font-size:11px">${esc(hw)}
        ${bayEditable?`<button type="button" class="blinkbtn" data-uid="${esc(p.uniqueId||'')}"
           title="Flash this drive's identify LED for 30s (needs an SES enclosure)">blink</button>`:''}</td>
    </tr>`;
  }).join('');
  if(bayEditable){
    tb.querySelectorAll('input[data-baykey]').forEach(inp=>{
      let t=null;
      inp.addEventListener('input',()=>{ clearTimeout(t);
        t=setTimeout(()=>saveBay(inp.dataset.baykey, inp.value, inp), 600); });
      inp.addEventListener('blur',()=>{ clearTimeout(t); saveBay(inp.dataset.baykey, inp.value, inp); });
    });
    // Identify LED. The hardware pointing at itself beats any map you could
    // write — when the hardware can do it. When it can't, say so on the button
    // rather than flashing a success state for a light that never lit.
    tb.querySelectorAll('.blinkbtn').forEach(b=>{
      b.addEventListener('click',async ()=>{
        const was=b.textContent;
        b.disabled=true; b.textContent='…';
        try{
          const r=await fetch('/api/identify',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({uniqueId:b.dataset.uid,seconds:30})});
          const j=await r.json().catch(()=>({}));
          if(r.ok && j.ok){
            b.textContent='blinking';
            b.classList.add('on');
            setTimeout(()=>{ b.textContent=was; b.classList.remove('on'); b.disabled=false; }, (j.seconds||30)*1000);
            return;
          }
          b.textContent='unsupported';
          b.classList.add('bad');
          b.title = j.error || ('HTTP '+r.status);
          setTimeout(()=>{ b.textContent=was; b.classList.remove('bad'); b.disabled=false; }, 4000);
        }catch(e){
          b.textContent='failed'; b.classList.add('bad'); b.title=String(e&&e.message||e);
          setTimeout(()=>{ b.textContent=was; b.classList.remove('bad'); b.disabled=false; }, 4000);
        }
      });
    });
  }
}

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
      drawMini(e.spark,[{data:h.read,color:rc,fill:TC.readFill},
                        {data:h.write,color:wc,fill:TC.writeFill}],null,56,SYSH);
    }
    // Direction matters: a READ on a tier means data is leaving it (being
    // promoted/demoted elsewhere); a WRITE means data is landing on it.
    setSpec(e.spark,{title:(t.instance||'tier')+' — Tier movement', unit:'MB/s', scale:MBs,
      maxPoints:SYSH, sampleMs:CFG.systemMs, series:[
        {data:h.read,color:rc,fill:TC.readFill,label:'Read off this tier'},
        {data:h.write,color:wc,fill:TC.writeFill,label:'Written to this tier'}]});

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
// ---- connection state -------------------------------------------------------
// fetch() DOES NOT REJECT on 4xx/5xx — it only rejects on a network failure. So
// `try{ await fetch(...) }catch{}` treats a 401 or a 500 as a completely
// successful request. The header dot used to be painted green and labelled
// "live" immediately after r.json() resolved, having established nothing except
// that a body parsed. The handler's own error path returns a VALID JSON body
// ({"error":...}) with status 500, so a server-side exception produced a green
// "live" dot and an "Invalid Date" clock. Three different failures, one green
// light. They are separated here and must never be collapsed again:
//   401  -> your session died. Auth, not storage.
//   5xx  -> the server is broken. Not the array.
//   throw-> the box is unreachable. Say how stale the screen is.
function setConn(state, detail){
  const el=$('#conn'); if(!el) return;
  const c = state==='live' ? 'var(--good)' : state==='stale' ? 'var(--warn)' : 'var(--bad)';
  const label = state==='live' ? 'live'
              : state==='servererr' ? 'server error'
              : state==='authfail' ? 'not authorised'
              : 'disconnected';
  el.innerHTML=`<span class="dot" style="background:${c}"></span>${label}`;
  el.title = detail || '';
}
// A non-OK response is never data. Returns null and paints the reason.
async function getJson(url){
  let r;
  try{ r = await fetch(url); }
  catch(e){ setConn('down','Cannot reach '+url+' — '+(e&&e.message||'network error')); return null; }
  if(r.status===401){ setConn('authfail','Session expired or key rotated ('+url+')'); return null; }
  if(!r.ok){ setConn('servererr','HTTP '+r.status+' from '+url+' — this is the dashboard process, not your storage'); return null; }
  try{ return await r.json(); }
  catch(e){ setConn('servererr','Malformed response from '+url); return null; }
}

async function pollSystem(){
  const d = await getJson('/api/system');
  if(d){ FEED_AT.system = Date.now(); renderSystem(d); }
}

async function pollPerf(){
  const d = await getJson('/api/perf');
  if(!d) return;                       // reason already painted by getJson
  try{
    // Only NOW is "live" an established fact.
    setConn('live');
    FEED_AT.perf = Date.now();
    // A drive whose counter instance vanished is visible here up to 5s before
    // the topology feed notices, so triage re-runs on the fast feed when the
    // set of failing drives changes.
    const prevBad = lastPerfData ? lastPerfData.disks.filter(x=>x.countersOk===false).length : 0;
    lastPerfData = d;
    const nowBad = d.disks.filter(x=>x.countersOk===false).length;
    if(nowBad!==prevBad && lastTopoData) renderTriage(lastTopoData, d);
    const ts=d.timestamp?new Date(d.timestamp):null;
    $('#clock').textContent=(ts && !isNaN(ts)) ? ts.toLocaleTimeString() : '–';
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
    // The disk TABLE gets the absent drives merged in; the aggregate views do
    // NOT — a drive that is gone contributes no I/O and must not drag a tier
    // average toward zero.
    // Recomputed here (not in renderDisks) because renderDisks receives the
    // absent drives merged in, and a drive with no counters has no latency.
    latOutliers = peerLatency(disks);
    renderDisks(withAbsentDrives(disks));
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
    drawMini($('#kReadSpark'), [{data:histR,color:cssVar('--read'), fill:TC.readFillHi}],null,28);
    drawMini($('#kWriteSpark'),[{data:histW,color:cssVar('--write'),fill:TC.writeFillHi}],null,28);
    drawMini($('#kIopsSpark'), [{data:histI,color:cssVar('--accent'),fill:TC.readFillHi}],null,28);

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
      fill:TC.accentFill, fillNeg:TC.writeFillHi}],100,28,MAXH,true);
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
    // A render fault is NOT a connection fault. Saying "disconnected" here sent
    // people hunting the network for a bug in this file.
    setConn('servererr','Render error: '+(e&&e.message||e));
    if(window.console) console.error('pollPerf render:', e);
  }
}

async function pollTopology(){
  const d = await getJson('/api/topology');
  if(!d) return;
  try{
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
      <td class="right mono">${fmtBytes(p.size)}</td><td>${statusCell(p.health,p.opStatus)}</td></tr>`);
    const vr=d.virtualDisks.map(v=>{ const used=v.size?Math.min(100,v.allocated/v.size*100):0;
      return `<tr data-ft="space" data-fk="${v.name}" title="Click to filter to this space">
      <td><b>${v.name}</b><div class="muted" style="font-size:11px">${v.resiliency||''} · ${v.provisioning||''}${v.writeCacheSize>0?' · WBC '+fmtBytes(v.writeCacheSize):''}</div></td>
      <td>${bar(used,'var(--muted)',fmtBytes(v.allocated)+' used')}</td>
      <td class="right mono">${fmtBytes(v.size)}</td><td>${statusCell(v.health,v.opStatus)}</td></tr>`; });
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
            <span class="mono muted">${fmtBytes(tot)} across ${v.tiers.length} tiers · ${statusCell(v.health,v.opStatus)}</span></div>
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
    renderTriage(d, lastPerfData);
    renderTimeline(d);
    renderBayMap(d);

    // tiers
    $('#tiers').innerHTML=d.tiers.length? d.tiers.map(t=>`<div style="display:flex;justify-content:space-between;padding:3px 0">
      <span>${typeTag(t.mediaType)} <b>${t.name}</b></span><span class="mono">${fmtBytes(t.size)}</span></div>`).join('')
      : '<span class="muted">No storage tiers configured.</span>';

    markActive();   // re-apply highlight after these tables were rebuilt
  }catch(e){
    // Keep last-good on screen, but SAY SO. "Keep last-good" rendered silently
    // is the difference between stale data and current data being invisible —
    // which during triage is the dashboard lying with a straight face.
    setConn('servererr','Topology render error (showing last good data): '+(e&&e.message||e));
    if(window.console) console.error('pollTopology render:', e);
  }
}

// Realtime loop is self-scheduling (setTimeout after each response completes)
// so requests never pile up if one is briefly slow — critical at ~100ms.
initTheme();      // before the first paint, so canvases bake the right colours
// History first: it is the one feed that can fill a chart before any live data
// has arrived, which is the entire reason it exists.
pollHistory();
setInterval(pollHistory, 60000);
loadBays();      // decides whether the bay editor is writable before it renders
loadAlerts();    // severity overrides must be known before triage first renders
// 1Hz is enough to make a stalled feed obvious without adding render churn at
// the 100ms cadence — and it only touches the DOM when something is actually late.
setInterval(stampPanelAges, 1000);
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
# Every write endpoint in this dashboard is loopback-only, and every one of them
# was repeating the same three steps: check IsLocal, read the body as UTF-8,
# parse it. Three copies of a security check is three chances to omit one.
#
# Returns the parsed body, or $null having already sent the error response — so
# a caller that forgets to check gets nothing rather than an unguarded object.
function Read-LocalJsonPost {
    param($Context, [string]$What = 'This')
    if ($Context.Request.HttpMethod -ne 'POST') {
        Send-Text $Context '{"error":"POST only"}' 'application/json' 405; return $null
    }
    if (-not $Context.Request.IsLocal) {
        Send-Text $Context ("{`"error`":`"$What can only be changed from the machine itself (loopback).`"}") 'application/json' 403
        return $null
    }
    try {
        # ALWAYS UTF-8: HttpListener falls back to the system codepage when a
        # request carries no charset, and browsers send none for JSON.
        $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd(); $reader.Close()
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Send-Text $Context ("{`"error`":`"$($_.Exception.Message -replace '"','\"')`"}") 'application/json' 400
        return $null
    }
}

function Send-Text {
    param($Context, [string]$Body, [string]$ContentType = 'text/html; charset=utf-8', [int]$Status = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    # The body is ALWAYS UTF-8, so always say so. Declaring a bare
    # 'application/json' left the charset to the client's default, which is the
    # mirror image of the request-side mojibake bug and would bite the first
    # time a bay label contained anything outside ASCII.
    if ($ContentType -notmatch 'charset=') { $ContentType = "$ContentType; charset=utf-8" }
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
# Injected into every collector runspace. Collectors run in FRESH runspaces, so
# a function defined out here is not visible to them — prepending the text is
# how they get to share code at all.
#
# This block was copy-pasted at the tail of all six collectors. It is also the
# shutdown path: every copy is a place to get Ctrl+C wrong, and we already lost
# an evening to a drain loop that forgot to check the stop flag.
#
# It is added to the runspace's INITIAL SESSION STATE, not prepended to the
# script text. Prepending looked simpler and silently broke all six collectors:
# $Script.ToString() returns a scriptblock's body WITHOUT its braces, so the
# concatenation put a function definition ahead of `param(...)` — and param must
# be the first statement in a script. The collectors kept running and simply
# never received their arguments.
$WaitIntervalBody = @'
    param($Shared, [int]$Ms)
    # Chunked so the stop flag is seen within ~100ms even on a 5-minute cadence.
    $left = $Ms
    while ($left -gt 0 -and -not $Shared['stop']) {
        $chunk = [math]::Min(100, $left)
        Start-Sleep -Milliseconds $chunk
        $left -= $chunk
    }
'@

function Start-Worker {
    param([scriptblock]$Script, [object[]]$Arguments)
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.Commands.Add(
        (New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry 'Wait-Interval', $WaitIntervalBody))
    $rs = [runspacefactory]::CreateRunspace($iss); $rs.Open()
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

# Drains the collector log queue to the console.
#
# This used to be an inline `while ($Shared['log'].Count -gt 0) { Write-Host }`
# with no bound and no stop check. On a HEALTHY system the queue is empty almost
# every pass, so it was invisible. On a DEGRADED pool the storage collector logs
# on every failed query, and a worker can enqueue faster than the console can
# render — at which point that loop never exits, the outer loop never re-checks
# $Shared['stop'], and Ctrl+C appears to do nothing.
#
# Bounded per pass, and it checks the stop flag itself. A tool whose job is
# degraded arrays must not become unkillable when an array degrades.
function Write-DrainLog {
    param([int]$Max = 200)
    $n = 0
    while ($script:Shared['log'].Count -gt 0 -and $n -lt $Max -and -not $script:Shared['stop']) {
        Write-Host ("  [{0:HH:mm:ss}] {1}" -f (Get-Date), $script:Shared['log'].Dequeue()) -ForegroundColor DarkYellow
        $n++
    }
    if ($script:Shared['log'].Count -gt 0 -and -not $script:Shared['stop']) {
        Write-Host ("  [{0:HH:mm:ss}] ... {1} more diagnostic line(s) queued" -f (Get-Date), $script:Shared['log'].Count) -ForegroundColor DarkGray
    }
}

# Register the event-log source once. Creating a source needs elevation, so this
# is best-effort: if it fails the dashboard carries on and simply doesn't mirror.
# Checked here rather than in the worker because New-EventLog is slow and the
# collector runs every 5s.
if (-not $NoEventLog) {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists('StorageSpacesDashboard')) {
            New-EventLog -LogName Application -Source 'StorageSpacesDashboard' -ErrorAction Stop
            Write-Host "  Registered event log source 'StorageSpacesDashboard' (Application log)." -ForegroundColor DarkGray
        }
        $script:Shared['evtLog'] = $true
    } catch {
        # SourceExists() THROWS when unelevated ("Inaccessible logs: Security")
        # rather than returning false, so the raw message is about searching
        # logs and reads like a much scarier problem than "not an admin".
        $why = if ($_.Exception.Message -match 'Inaccessible logs|Security') { 'needs elevation' }
               else { $_.Exception.Message.Trim() }
        Write-Host "  Event log mirroring off ($why). Everything else works." -ForegroundColor DarkGray
    }
}

# ---- bay map persistence ----------------------------------------------------
# Sits next to the script. Plain JSON so you can edit it in Notepad, keep it in
# source control, or copy it to the next machine. Absent is normal, not an error.
$script:BaysPath = Join-Path (Split-Path -Parent $PSCommandPath) 'bays.json'
# ---------------------------------------------------------------------------
# Flat string->string maps persisted as JSON beside the script. Two of these now
# exist (bay labels, alert overrides) and they had byte-identical load/save
# logic. One implementation, two call sites.
#
# Deliberately NOT a general config system: these are the only two things this
# tool keeps on disk, both of them human judgements that must survive a restart.
# ---------------------------------------------------------------------------
function Import-JsonMap {
    param([string]$Path, [string]$Key, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $obj = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { if ("$($p.Value)".Trim()) { $h["$($p.Name)"] = "$($p.Value)".Trim() } }
        $script:Shared[$Key] = $h
        Write-Host "  ${Label}: $($h.Count) entr$(if($h.Count -eq 1){'y'}else{'ies'}) from $Path" -ForegroundColor DarkGray
    } catch {
        Write-Host "  ${Label}: could not read $Path — $($_.Exception.Message.Trim())" -ForegroundColor Yellow
    }
}
function Export-JsonMap {
    param([string]$Path, [string]$Key)
    try {
        $h = $script:Shared[$Key]
        ($h.GetEnumerator() | Sort-Object Name | ForEach-Object -Begin { $o=[ordered]@{} } `
            -Process { $o[$_.Key] = $_.Value } -End { [pscustomobject]$o }) |
            ConvertTo-Json -Depth 3 |
            Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
        return $true
    } catch {
        $script:Shared['log'].Enqueue("${Key}: save failed - $($_.Exception.Message)")
        return $false
    }
}
function Import-Bays  { Import-JsonMap -Path $script:BaysPath   -Key 'bays'   -Label 'Bay map' }
function Export-Bays  { Export-JsonMap -Path $script:BaysPath   -Key 'bays' }
$script:AlertsPath = Join-Path (Split-Path -Parent $PSCommandPath) 'alerts.json'
function Import-Alerts { Import-JsonMap -Path $script:AlertsPath -Key 'alerts' -Label 'Alert rules' }
function Export-Alerts { Export-JsonMap -Path $script:AlertsPath -Key 'alerts' }

Import-Bays
Import-Alerts

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
            Write-DrainLog
            if ($script:Shared['stop'] -or -not $listener.IsListening) { break }
        }
        Write-DrainLog
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
                '/api/history'   {
                    # Built on demand rather than cached: it's requested every
                    # few seconds, not 10x a second, and serialising ~900 points
                    # per series is far cheaper than keeping a second copy of it
                    # in sync with the writer.
                    $h = $script:Shared['hist']
                    $drv = @{}
                    foreach ($k in @($h['d'].Keys)) {
                        $drv[$k] = [pscustomobject]@{
                            busy = @($h['d'][$k]['busy']); r = @($h['d'][$k]['r']); w = @($h['d'][$k]['w'])
                        }
                    }
                    $cap = @{}
                    foreach ($k in @($script:Shared['capHist'].Keys)) { $cap[$k] = @($script:Shared['capHist'][$k]) }
                    $body = [pscustomobject]@{
                        sampleMs = 1000
                        t        = @($h['t'])
                        totals   = [pscustomobject]@{ r=@($h['r']); w=@($h['w']); i=@($h['i']) }
                        drives   = [pscustomobject]$drv
                        capacity = [pscustomobject]$cap
                    } | ConvertTo-Json -Depth 6 -Compress
                    Send-Text $ctx $body 'application/json'
                }
                '/api/bundle'    {
                    # Everything the dashboard knows, in one file: current
                    # topology, the event timeline, the 15-minute history ring,
                    # capacity trend, and the collector diagnostics. For the
                    # forum post, the ticket, or just remembering what December
                    # looked like.
                    #
                    # Assembled from the already-serialised feeds rather than by
                    # re-querying storage — this must never be the request that
                    # makes a struggling array worse.
                    $h = $script:Shared['hist']
                    $drv = @{}
                    foreach ($k in @($h['d'].Keys)) {
                        $drv[$k] = [pscustomobject]@{ busy=@($h['d'][$k]['busy']); r=@($h['d'][$k]['r']); w=@($h['d'][$k]['w']) }
                    }
                    $cap = @{}
                    foreach ($k in @($script:Shared['capHist'].Keys)) { $cap[$k] = @($script:Shared['capHist'][$k]) }
                    $stamp = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
                    # try/catch is a STATEMENT in PS 5.1, not an expression, so it
                    # cannot sit inside a hashtable literal. Hoisted.
                    $bTopo = $null; $bPerf = $null; $bSys = $null; $bOs = $null
                    try { if ($script:Shared['topoJson'])   { $bTopo = $script:Shared['topoJson']   | ConvertFrom-Json } } catch {}
                    try { if ($script:Shared['perfJson'])   { $bPerf = $script:Shared['perfJson']   | ConvertFrom-Json } } catch {}
                    try { if ($script:Shared['systemJson']) { $bSys  = $script:Shared['systemJson'] | ConvertFrom-Json } } catch {}
                    try { $bOs = "$((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption)" } catch { $bOs = 'unknown' }
                    $body = [pscustomobject]@{
                        generated   = (Get-Date).ToString('o')
                        host        = $script:HostName
                        elevated    = [bool]$script:IsElevated
                        dashboard   = [pscustomobject]@{
                            port = $Port; sampleMs = $SampleMs; topologyMs = $TopologyMs
                            systemMs = $SystemMs; jobsMs = $JobsMs; wearMs = $WearMs; layoutMs = $LayoutMs
                            bindAll = [bool]$BindAll; exactLayout = [bool]$ExactLayout
                        }
                        os          = [pscustomobject]@{
                            caption   = $bOs
                            version   = "$([System.Environment]::OSVersion.Version)"
                            psVersion = "$($PSVersionTable.PSVersion)"
                        }
                        topology    = $bTopo
                        realtime    = $bPerf
                        system      = $bSys
                        events      = @($script:Shared['events'])
                        history     = [pscustomobject]@{
                            sampleMs = 1000; t = @($h['t'])
                            totals = [pscustomobject]@{ r=@($h['r']); w=@($h['w']); i=@($h['i']) }
                            drives = [pscustomobject]$drv
                        }
                        capacity    = [pscustomobject]$cap
                        wearProgress= $script:Shared['wearProgress']
                    } | ConvertTo-Json -Depth 8
                    $ctx.Response.Headers['Content-Disposition'] =
                        "attachment; filename=""storage-bundle_$($script:HostName)_$stamp.json"""
                    Send-Text $ctx $body 'application/json'
                }
                '/api/bays'      {
                    if ($ctx.Request.HttpMethod -eq 'POST') {
                        # The only write endpoint in the whole dashboard, so it
                        # gets the rule we settled on for auth: LOOPBACK ONLY.
                        # If you are at the console you have already proven more
                        # than a password could; if you are not, you cannot
                        # relabel someone's drive bays. There is deliberately no
                        # override switch for this.
                        $in = Read-LocalJsonPost $ctx 'Bay labels'
                        if ($null -eq $in) { break }
                        try {
                            $key = "$($in.key)".Trim()
                            $lbl = "$($in.bay)".Trim()
                            if (-not $key) { throw "missing key" }
                            $h = $script:Shared['bays']
                            # An empty label CLEARS the entry rather than storing
                            # a blank one — otherwise bays.json slowly fills with
                            # empty strings that look like real answers.
                            if ($lbl) { $h[$key] = $lbl } elseif ($h.ContainsKey($key)) { $h.Remove($key) }
                            $script:Shared['bays'] = $h
                            $ok = Export-Bays
                            Send-Text $ctx ("{`"ok`":$($ok.ToString().ToLower()),`"count`":$($h.Count)}") 'application/json'
                        } catch {
                            Send-Text $ctx ("{`"error`":`"$($_.Exception.Message -replace '"','\"')`"}") 'application/json' 400
                        }
                    } else {
                        $h = $script:Shared['bays']
                        $o = [ordered]@{}
                        foreach ($k in ($h.Keys | Sort-Object)) { $o[$k] = $h[$k] }
                        Send-Text $ctx ([pscustomobject]@{
                            editable = [bool]$ctx.Request.IsLocal
                            path     = "$script:BaysPath"
                            bays     = [pscustomobject]$o
                        } | ConvertTo-Json -Depth 3) 'application/json'
                    }
                }
                '/api/alerts'    {
                    if ($ctx.Request.HttpMethod -eq 'POST') {
                        $in = Read-LocalJsonPost $ctx 'Alert rules'
                        if ($null -eq $in) { break }
                        try {
                            $key = "$($in.key)".Trim()
                            $lvl = "$($in.level)".Trim().ToLower()
                            if (-not $key) { throw 'missing key' }
                            if ($lvl -and $lvl -notin @('hidden','info','warn')) { throw "level must be hidden, info or warn" }
                            $h = $script:Shared['alerts']
                            # Empty level RESTORES the finding to its natural severity.
                            if ($lvl) { $h[$key] = $lvl } elseif ($h.ContainsKey($key)) { $h.Remove($key) }
                            $script:Shared['alerts'] = $h
                            $ok = Export-Alerts
                            Send-Text $ctx ("{`"ok`":$($ok.ToString().ToLower()),`"count`":$($h.Count)}") 'application/json'
                        } catch {
                            Send-Text $ctx ("{`"error`":`"$($_.Exception.Message -replace '"','\"')`"}") 'application/json' 400
                        }
                    } else {
                        $h = $script:Shared['alerts']
                        $o = [ordered]@{}
                        foreach ($k in ($h.Keys | Sort-Object)) { $o[$k] = $h[$k] }
                        Send-Text $ctx ([pscustomobject]@{
                            editable = [bool]$ctx.Request.IsLocal
                            path     = "$script:AlertsPath"
                            rules    = [pscustomobject]$o
                        } | ConvertTo-Json -Depth 3) 'application/json'
                    }
                }
                '/api/identify'  {
                    # Blink the drive's identify LED — the real answer to "which
                    # drawer", better than any map because the hardware points at
                    # itself. Needs an enclosure that speaks SES; most direct-
                    # attach consumer kit does not, and when it doesn't we say so
                    # plainly rather than returning success and blinking nothing.
                    $in = Read-LocalJsonPost $ctx 'Identify'
                    if ($null -eq $in) { break }
                    try {
                        $uid = "$($in.uniqueId)".Trim()
                        $secs = if ($in.seconds) { [int]$in.seconds } else { 30 }
                        if ($secs -lt 1)   { $secs = 1 }
                        if ($secs -gt 300) { $secs = 300 }
                        if (-not $uid) { throw 'missing uniqueId' }

                        $pdisk = Get-PhysicalDisk -UniqueId $uid -ErrorAction Stop
                        $off   = [bool]$in.off

                        if ($off) {
                            try   { Disable-PhysicalDiskIndication    -InputObject $pdisk -ErrorAction Stop }
                            catch { Disable-PhysicalDiskIdentification -InputObject $pdisk -ErrorAction Stop }
                            $script:Shared['identify'] = $null
                            Send-Text $ctx '{"ok":true,"state":"off"}' 'application/json'
                        } else {
                            # Cmdlet name differs by Windows version: Indication on
                            # 2012 R2-era builds, Identification on current ones.
                            $err = $null
                            try   { Enable-PhysicalDiskIndication    -InputObject $pdisk -ErrorAction Stop }
                            catch {
                                $err = $_.Exception.Message
                                try   { Enable-PhysicalDiskIdentification -InputObject $pdisk -ErrorAction Stop; $err = $null }
                                catch { $err = $_.Exception.Message }
                            }
                            if ($err) {
                                # Do NOT just assume "no SES enclosure". The first
                                # version said exactly that and was wrong: on an
                                # unelevated dashboard the cmdlet returns "Access
                                # denied", which is a completely different problem
                                # with a completely different fix. Read the error
                                # before naming the cause.
                                $why = if ($err -match 'access is denied|access denied|privilege') {
                                    'Identify needs an ELEVATED dashboard. Restart it as Administrator.'
                                } elseif ($err -match 'not supported|not implemented|invalid') {
                                    'This drive/enclosure does not support identify LEDs (needs SCSI Enclosure Services).'
                                } else {
                                    'Could not switch the identify LED on.'
                                }
                                Send-Text $ctx ([pscustomobject]@{
                                    ok = $false; error = $why; detail = "$err"
                                } | ConvertTo-Json) 'application/json' 501
                            } else {
                                $script:Shared['identify'] = [pscustomobject]@{
                                    uniqueId = $uid; until = [datetime]::UtcNow.AddSeconds($secs)
                                }
                                Send-Text $ctx ("{`"ok`":true,`"state`":`"on`",`"seconds`":$secs}") 'application/json'
                            }
                        }
                    } catch {
                        Send-Text $ctx ("{`"ok`":false,`"error`":`"$($_.Exception.Message -replace '"','\"')`"}") 'application/json' 400
                    }
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
