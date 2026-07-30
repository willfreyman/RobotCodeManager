# Builds RCM.exe from RCM.ps1.
#
# Run this again after editing the .ps1 - the script is embedded in the .exe, so
# edits do not take effect until you rebuild.
#
#   powershell -ExecutionPolicy Bypass -File .\Build-Exe.ps1
#   powershell -ExecutionPolicy Bypass -File .\Build-Exe.ps1 -OutputDir "C:\path\to\project"
#
# Uses the C# compiler that ships with the .NET Framework, so nothing needs to
# be downloaded or installed.

[CmdletBinding()]
param(
    # Left empty on purpose: $PSScriptRoot is not populated while param defaults
    # are evaluated, so it is filled in from the script body below.
    [string]$OutputDir,
    [string]$Name = "RCM.exe",

    # Extra folders to drop a copy of the finished .exe into, e.g. the robot
    # project you normally launch it from. Defaults to CopyToDefault below.
    [string[]]$CopyTo,

    # Close a running copy of the target .exe instead of failing. Refuses while a
    # build or deploy is in flight unless -Force is also given.
    [switch]$StopRunning,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = $scriptDir }

# Folders that should always receive a copy of the finished .exe, so the build
# and the project you launch from never drift apart. Paths are relative to the
# folder above this one, which is where the robot projects live. Change this to
# your own project, use -CopyTo, or set it to @() to only build in place.
$CopyToDefault = @('SWERVE_BEST')

function Test-FileLocked {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    # Asking the filesystem directly is authoritative. A process query is not: if
    # WMI returns nothing (it can fail or come back empty under load) the answer
    # looks like "not running", which is the dangerous direction to guess in.
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $stream.Close()
        $stream.Dispose()
        return $false
    }
    catch {
        return $true
    }
}

function Get-RunningInstanceIds {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)

    $ids = @()
    try {
        $ids = @(Get-CimInstance Win32_Process -ErrorAction Stop |
                 Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $full) } |
                 ForEach-Object { [int]$_.ProcessId })
    }
    catch {
        $ids = @()
    }

    if ($ids.Count -eq 0) {
        # Independent route in case the WMI query failed or returned nothing.
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($full)
        $ids = @(Get-Process -Name $leaf -ErrorAction SilentlyContinue |
                 Where-Object { $_.Path -and ($_.Path -ieq $full) } |
                 ForEach-Object { [int]$_.Id })
    }

    return $ids
}

function Test-InstanceBusy {
    param([int[]]$ProcessIds)
    if (-not $ProcessIds -or $ProcessIds.Count -eq 0) { return $false }
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $children = @($all | Where-Object { $ProcessIds -contains $_.ParentProcessId })
    $grandchildren = @($all | Where-Object { @($children.ProcessId) -contains $_.ParentProcessId })
    # A gradle or git descendant means work is in progress; conhost is just the
    # console the hidden PowerShell host owns.
    return @($grandchildren | Where-Object {
        $_.Name -in @('cmd.exe', 'java.exe', 'javaw.exe', 'git.exe')
    }).Count -gt 0
}

$scriptSource = Join-Path $scriptDir "RCM.ps1"
$launcherSource = Join-Path $scriptDir "ExeLauncher.cs"

foreach ($required in @($scriptSource, $launcherSource)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required file not found: $required"
    }
}

# Fail early on a syntax error rather than shipping a broken .exe.
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptSource, [ref]$null, [ref]$parseErrors) | Out-Null
if ($parseErrors -and $parseErrors.Count -gt 0) {
    foreach ($parseError in $parseErrors) {
        Write-Host "  line $($parseError.Extent.StartLineNumber): $($parseError.Message)" -ForegroundColor Red
    }
    throw "RCM.ps1 has $($parseErrors.Count) syntax error(s). The .exe was not built."
}
Write-Host "Script parsed cleanly." -ForegroundColor Green

$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path -LiteralPath $csc)) {
    throw "csc.exe was not found. Install the .NET Framework 4.x developer files."
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}
$outputPath = Join-Path (Resolve-Path -LiteralPath $OutputDir).Path $Name

# csc reports a locked output file as a bare CS0016, which says nothing about the
# real cause: the app is open.
if (Test-FileLocked -Path $outputPath) {
    $ids = @(Get-RunningInstanceIds -Path $outputPath)
    $where = if ($ids.Count -gt 0) { " (PID $($ids -join ', '))" } else { "" }

    if (-not $StopRunning) {
        throw ("$Name is open$where, so it cannot be overwritten. Close the app, " +
               "or re-run with -StopRunning.")
    }
    if ((Test-InstanceBusy -ProcessIds $ids) -and -not $Force) {
        throw ("$Name is open$where and looks like it is in the middle of a build or deploy. " +
               "Let it finish, or re-run with -StopRunning -Force to kill it anyway.")
    }

    if ($ids.Count -eq 0) {
        throw ("$Name is locked by another process, but no matching process could be found. " +
               "Close it by hand and try again.")
    }

    Write-Host "Closing $($ids.Count) running instance(s) of $Name ..." -ForegroundColor Yellow
    foreach ($processId in $ids) { & taskkill.exe /PID $processId /T /F 2>&1 | Out-Null }
    Start-Sleep -Seconds 2

    if (Test-FileLocked -Path $outputPath) {
        throw "$Name is still locked after trying to close it."
    }
}

# The resource name must match ExeLauncher.cs. csc derives it from the file name,
# so the script is staged under the exact name the launcher looks up.
$stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("rcm-build-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null
try {
    $stagedScript = Join-Path $stagingDir "RCM.ps1"
    Copy-Item -LiteralPath $scriptSource -Destination $stagedScript

    $cscArgs = New-Object System.Collections.Generic.List[string]
    $cscArgs.Add("/nologo")
    $cscArgs.Add("/target:winexe")          # no console window
    $cscArgs.Add("/optimize+")
    $cscArgs.Add("/platform:anycpu")
    $cscArgs.Add("/out:$outputPath")
    $cscArgs.Add("/reference:System.dll")
    $cscArgs.Add("/reference:System.Windows.Forms.dll")
    $cscArgs.Add("/reference:System.Drawing.dll")
    $cscArgs.Add("/resource:$stagedScript,RCM.ps1")

    # Artwork: RCM.ico becomes the .exe's own icon in Explorer and the taskbar,
    # and both files are embedded so the .exe stays a single portable file.
    $iconSource = Join-Path $scriptDir "RCM.ico"
    $logoSource = Join-Path $scriptDir "RCM.png"

    if (Test-Path -LiteralPath $iconSource) {
        $cscArgs.Add("/win32icon:$iconSource")
        $stagedIcon = Join-Path $stagingDir "RCM.ico"
        Copy-Item -LiteralPath $iconSource -Destination $stagedIcon
        $cscArgs.Add("/resource:$stagedIcon,RCM.ico")
    } else {
        Write-Host "  RCM.ico not found - the .exe will use the default icon." -ForegroundColor Yellow
    }

    if (Test-Path -LiteralPath $logoSource) {
        $stagedLogo = Join-Path $stagingDir "RCM.png"
        Copy-Item -LiteralPath $logoSource -Destination $stagedLogo
        $cscArgs.Add("/resource:$stagedLogo,RCM.png")
    } else {
        Write-Host "  RCM.png not found - the window will show a text heading." -ForegroundColor Yellow
    }

    $cscArgs.Add($launcherSource)

    Write-Host "Compiling $outputPath ..."
    $output = & $csc @($cscArgs.ToArray()) 2>&1
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "csc.exe failed with exit code $LASTEXITCODE."
    }
    if ($output) { $output | ForEach-Object { Write-Host $_ } }
}
finally {
    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
}

$info = Get-Item -LiteralPath $outputPath
Write-Host ""
Write-Host "Built: $($info.FullName)" -ForegroundColor Green
Write-Host "Size : $([math]::Round($info.Length / 1KB, 1)) KB"
Write-Host "Embedded script: $([math]::Round((Get-Item -LiteralPath $scriptSource).Length / 1KB, 1)) KB"

# Distribute copies. A stale copy in a project folder is worse than none, so a
# destination that cannot be written is reported rather than skipped quietly.
$destinations = if ($PSBoundParameters.ContainsKey('CopyTo')) { $CopyTo } else { $CopyToDefault }
$projectsRoot = Split-Path -Parent $scriptDir

foreach ($destination in $destinations) {
    if ([string]::IsNullOrWhiteSpace($destination)) { continue }

    $target = if ([System.IO.Path]::IsPathRooted($destination)) {
        $destination
    } else {
        Join-Path $projectsRoot $destination
    }

    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host "  SKIPPED $target (folder not found)" -ForegroundColor Yellow
        continue
    }

    $targetExe = Join-Path $target $Name
    if ([System.IO.Path]::GetFullPath($targetExe) -ieq [System.IO.Path]::GetFullPath($outputPath)) {
        continue      # already built straight into this folder
    }

    if (Test-FileLocked -Path $targetExe) {
        $ids = @(Get-RunningInstanceIds -Path $targetExe)
        if (-not $StopRunning) {
            Write-Host "  FAILED  $targetExe is open$(if ($ids.Count) { " (PID $($ids -join ', '))" }). Copy not updated." -ForegroundColor Red
            continue
        }
        foreach ($processId in $ids) { & taskkill.exe /PID $processId /T /F 2>&1 | Out-Null }
        Start-Sleep -Seconds 2
    }

    try {
        Copy-Item -LiteralPath $outputPath -Destination $targetExe -Force -ErrorAction Stop
        Write-Host "Copied to: $targetExe" -ForegroundColor Green
    }
    catch {
        Write-Host "  FAILED  $targetExe : $($_.Exception.Message)" -ForegroundColor Red
    }
}
