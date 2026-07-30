# RCM - Robot Code Manager
#
# Built by 416aab - Will Freyman, for Nightbots FRC 10686.
#
# Single-file Windows launcher for WPILib robot projects.
#
# Right-click -> Run with PowerShell. Windows PowerShell 5.1+ / PowerShell 7.
#
# The script does not have to live inside a project. If there is no WPILib
# project beside it, it scans nearby folders and asks which project to open,
# then remembers that choice.
#
# The Build and Deploy commands are built to match what the WPILib VS Code
# extension runs, so results here and in VS Code agree:
#
#   Build:  cmd.exe /d /c gradlew.bat build [--offline] -Dorg.gradle.java.home="<jdk>"
#   Deploy: cmd.exe /d /c gradlew.bat deploy -PteamNumber=<n> [-xcheck] [--offline] -Dorg.gradle.java.home="<jdk>"
#
# with JAVA_HOME set to the same JDK. See vscode-wpilib: src/utilities.ts
# (gradleRun), src/java/buildtest.ts, src/java/deploydebug.ts, src/executor.ts.

param(
    # Optional project folder to open, e.g. from a shortcut:
    #   RCM.exe "C:\path\to\robot project"
    [string]$Project
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------- Script state ----------------

$script:ScriptDir = if ($env:RCM_SCRIPT_DIR -and (Test-Path -LiteralPath $env:RCM_SCRIPT_DIR)) {
    # Set by the .exe wrapper, which runs a copy of this script from the temp
    # folder. Without this, project discovery would look in the temp folder.
    $env:RCM_SCRIPT_DIR
} elseif ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    (Get-Location).Path
}

$script:ProjectRoot   = $null    # active WPILib project folder
$script:IsBusy        = $false
$script:RepoState     = $null
$script:CurrentProcess = $null   # running gradle/git process, for Cancel
$script:CancelRequested = $false
$script:JdkPath       = $null
$script:JdkMajor      = 0
$script:JdkChecked    = $false
$script:TeamNumber    = $null
$script:ProjectYear   = $null
$script:Settings      = $null
$script:UiReady       = $false

# ---------------- Identity ----------------

$script:AppName    = "RCM"
$script:AppLongName = "Robot Code Manager"
$script:AppVersion = "1.0"
$script:AppTeam    = "Nightbots  -  FRC 10686"
$script:AppAuthor  = "416aab - Will Freyman"

# Brand palette, kept in one place so the whole window stays consistent.
$script:ColInk     = [System.Drawing.Color]::FromArgb(24, 28, 38)     # near-black text
$script:ColMuted   = [System.Drawing.Color]::FromArgb(112, 118, 128)  # secondary text
$script:ColLine    = [System.Drawing.Color]::FromArgb(214, 219, 226)  # borders
$script:ColSurface = [System.Drawing.Color]::FromArgb(245, 247, 250)  # window background
$script:ColBar     = [System.Drawing.Color]::FromArgb(235, 239, 244)  # toolbars
# Sampled straight out of RCM.png: the bright bar green. Used for the stripe and
# other decoration, where nothing has to stay readable on top of it.
$script:ColAccent  = [System.Drawing.Color]::FromArgb(25, 161, 29)
# A darker mix of the same hue for the Deploy button. The logo green is too
# bright to carry white label text at a comfortable contrast.
$script:ColGo      = [System.Drawing.Color]::FromArgb(24, 126, 40)
$script:ColBuild   = [System.Drawing.Color]::FromArgb(36, 86, 150)    # build
$script:ColDanger  = [System.Drawing.Color]::FromArgb(168, 48, 48)    # cancel
$script:ColOff     = [System.Drawing.Color]::FromArgb(214, 218, 224)  # disabled fill
$script:ColOffText = [System.Drawing.Color]::FromArgb(132, 136, 143)  # disabled text

$script:SettingsPath = Join-Path $env:LOCALAPPDATA "RCM\settings.json"
$script:LegacySettingsPath = Join-Path $env:LOCALAPPDATA "NightbotsRobotCodeManager\settings.json"

# Directory names never worth scanning when looking for projects.
$script:SkipDirs = @('build', '.git', '.gradle', 'node_modules', 'bin', 'obj', '.vscode', 'logs')

# Minimum Java major version the WPILib toolchain needs, by project year.
# vscode-wpilib v2026.2.1 requires 17; the 2027 line moved to 25. Add a row here
# when a new season changes the requirement.
$script:MinJavaByYear = @{ '2026' = 17; '2027' = 25 }
$script:DefaultMinJava = 17

# ---------------- Branding ----------------

$script:AppIcon = $null
$script:AppLogo = $null

function Load-BrandAssets {
    # The .exe unpacks the icon and logo beside the temp copy of the script and
    # points at them with environment variables. Running the .ps1 directly
    # instead, they are picked up from the script's own folder.
    $iconPath = if ($env:RCM_ICON -and (Test-Path -LiteralPath $env:RCM_ICON)) {
        $env:RCM_ICON
    } else {
        Join-Path $script:ScriptDir "RCM.ico"
    }
    $logoPath = if ($env:RCM_LOGO -and (Test-Path -LiteralPath $env:RCM_LOGO)) {
        $env:RCM_LOGO
    } else {
        Join-Path $script:ScriptDir "RCM.png"
    }

    # Both are read through a MemoryStream rather than with Icon/Image.FromFile,
    # which holds the file open for the life of the object and would block the
    # next rebuild. The streams stay referenced because GDI+ reads from them
    # lazily; disposing them would break the image later on.
    if (Test-Path -LiteralPath $iconPath) {
        try {
            $script:IconStream = New-Object System.IO.MemoryStream(
                ,[System.IO.File]::ReadAllBytes($iconPath))
            $script:AppIcon = New-Object System.Drawing.Icon($script:IconStream)
        }
        catch { $script:AppIcon = $null }
    }

    if (Test-Path -LiteralPath $logoPath) {
        try {
            $script:LogoStream = New-Object System.IO.MemoryStream(
                ,[System.IO.File]::ReadAllBytes($logoPath))
            $script:AppLogo = [System.Drawing.Image]::FromStream($script:LogoStream)
        }
        catch { $script:AppLogo = $null }
    }
}

function Set-DialogIcon {
    param([System.Windows.Forms.Form]$Dialog)
    if ($null -ne $script:AppIcon) { $Dialog.Icon = $script:AppIcon }
}

# ---------------- Small helpers ----------------

function Quote-Argument {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '""' }
    # Leave clean arguments unquoted so logged command lines stay readable and
    # match what VS Code prints.
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Append-Log {
    param([string]$Text)
    if ($null -eq $txtOutput) { return }

    # Gradle can emit a lot of text. Keep the box bounded so long sessions do
    # not slow the UI down or exhaust memory.
    if ($txtOutput.TextLength -gt 600000) {
        $keep = $txtOutput.Text.Substring($txtOutput.TextLength - 300000)
        $txtOutput.Text = "... earlier output trimmed ...`r`n" + $keep
    }

    $txtOutput.AppendText($Text)
    $txtOutput.SelectionStart = $txtOutput.TextLength
    $txtOutput.ScrollToCaret()
}

function Show-Error {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show(
        $form, $Message, "RCM",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Show-Info {
    param([string]$Message, [string]$Title = "RCM")
    [System.Windows.Forms.MessageBox]::Show(
        $form, $Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Show-WarningConfirm {
    param([string]$Message, [string]$Title = "Confirm")
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $form, $Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    return $answer -eq [System.Windows.Forms.DialogResult]::Yes
}

function Show-InputDialog {
    param(
        [string]$Prompt,
        [string]$Title = "RCM",
        [string]$Default = "",
        [switch]$Multiline
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $dialog.ClientSize = New-Object System.Drawing.Size(480, $(if ($Multiline) { 210 } else { 145 }))
    Set-DialogIcon $dialog

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Prompt
    $label.Location = New-Object System.Drawing.Point(14, 14)
    $label.Size = New-Object System.Drawing.Size(452, 34)
    $dialog.Controls.Add($label)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Text = $Default
    $box.Location = New-Object System.Drawing.Point(14, 52)
    if ($Multiline) {
        $box.Multiline = $true
        $box.ScrollBars = "Vertical"
        $box.Size = New-Object System.Drawing.Size(452, 108)
        $box.AcceptsReturn = $true
    } else {
        $box.Size = New-Object System.Drawing.Size(452, 24)
    }
    $dialog.Controls.Add($box)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "OK"
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Size = New-Object System.Drawing.Size(88, 28)
    $ok.Location = New-Object System.Drawing.Point(284, ($dialog.ClientSize.Height - 40))
    $dialog.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancel"
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Size = New-Object System.Drawing.Size(88, 28)
    $cancel.Location = New-Object System.Drawing.Point(378, ($dialog.ClientSize.Height - 40))
    $dialog.Controls.Add($cancel)

    # Enter submits only in single-line mode; the multiline box needs Enter.
    if (-not $Multiline) { $dialog.AcceptButton = $ok }
    $dialog.CancelButton = $cancel

    try {
        $result = $dialog.ShowDialog($form)
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return $box.Text
    }
    finally {
        $dialog.Dispose()
    }
}

# ---------------- Settings ----------------

function Load-Settings {
    $defaults = [PSCustomObject]@{
        lastProject   = ""
        offlineBuild  = $false   # matches wpilib.offline default
        offlineDeploy = $true    # matches wpilib.deployOffline default
        skipTests     = $false   # matches wpilib.skipTests default
        taskCounts    = [PSCustomObject]@{}   # per project+task Gradle task counts
        recentProjects = @()     # projects used before, newest first
        searchRoots    = @()     # folders known to contain robot projects
    }

    # Carry over settings saved under the old name so the remembered project and
    # the calibrated task counts survive the rename.
    $sourcePath = $script:SettingsPath
    if ((-not (Test-Path $sourcePath)) -and (Test-Path $script:LegacySettingsPath)) {
        $sourcePath = $script:LegacySettingsPath
    }

    if (-not (Test-Path $sourcePath)) {
        $script:Settings = $defaults
        return
    }

    try {
        $loaded = Get-Content -Path $sourcePath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($name in @('lastProject', 'offlineBuild', 'offlineDeploy', 'skipTests', 'taskCounts')) {
            if ($null -ne $loaded.$name) { $defaults.$name = $loaded.$name }
        }
        # A single-element JSON array can come back as a bare string.
        foreach ($name in @('recentProjects', 'searchRoots')) {
            if ($null -ne $loaded.$name) { $defaults.$name = @($loaded.$name) }
        }
    }
    catch {
        # A corrupt settings file must never stop the launcher.
    }

    $script:Settings = $defaults
}

function Save-Settings {
    try {
        $dir = Split-Path -Parent $script:SettingsPath
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $script:Settings | ConvertTo-Json | Set-Content -Path $script:SettingsPath -Encoding UTF8
    }
    catch {
        Append-Log "Could not save settings: $($_.Exception.Message)`r`n"
    }
}

# ---------------- Gradle task-count baselines ----------------
# Gradle with --console=plain reports no percentage, but it does print one
# "> Task :name" line per task. Counting those against the number of tasks the
# last successful run of the same task produced gives an honest progress bar
# that calibrates itself per project.

function Get-TaskBaseline {
    param([string]$Task)

    $key = "$($script:ProjectRoot)|$Task"
    $counts = $script:Settings.taskCounts
    if ($null -ne $counts -and $null -ne $counts.$key) {
        $value = 0
        if ([int]::TryParse([string]$counts.$key, [ref]$value) -and $value -gt 0) { return $value }
    }

    # First-run guesses. A measured clean build emits about 14; deploy adds the
    # artifact and roboRIO steps. Both are replaced by real numbers after one run.
    if ($Task -eq 'deploy') { return 30 }
    return 14
}

function Set-TaskBaseline {
    param([string]$Task, [int]$Count)
    if ($Count -le 0) { return }
    if ($null -eq $script:Settings.taskCounts) {
        $script:Settings.taskCounts = [PSCustomObject]@{}
    }
    $script:Settings.taskCounts | Add-Member -NotePropertyName "$($script:ProjectRoot)|$Task" `
                                             -NotePropertyValue $Count -Force
    Save-Settings
}

# ---------------- Project discovery ----------------

function Test-IsWpilibProject {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Path "gradlew.bat"))) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path "build.gradle")) -or
           (Test-Path -LiteralPath (Join-Path $Path "build.gradle.kts"))
}

function Find-WpilibProjects {
    param([string]$StartDir, [int]$MaxDepth = 2)

    $found = New-Object System.Collections.Generic.List[string]
    if (Test-IsWpilibProject $StartDir) { $found.Add((Resolve-Path -LiteralPath $StartDir).Path) }

    $frontier = @($StartDir)
    for ($depth = 1; $depth -le $MaxDepth; $depth++) {
        $next = New-Object System.Collections.Generic.List[string]
        foreach ($dir in $frontier) {
            $children = @()
            try {
                $children = Get-ChildItem -LiteralPath $dir -Directory -ErrorAction Stop
            }
            catch { continue }

            foreach ($child in $children) {
                if ($script:SkipDirs -contains $child.Name.ToLowerInvariant()) { continue }
                if ($child.Name.StartsWith('.')) { continue }
                if (Test-IsWpilibProject $child.FullName) {
                    $found.Add($child.FullName)
                } else {
                    $next.Add($child.FullName)
                }
            }
        }
        $frontier = $next
    }

    return @($found | Select-Object -Unique)
}

function Add-SearchRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }

    # A drive root would drag the whole disk into every scan.
    $trimmed = $Path.TrimEnd('\', '/')
    if ($trimmed -match '^[A-Za-z]:$') { return }

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($existing in @($script:Settings.searchRoots)) {
        if ($existing -and -not ($roots | Where-Object { $_ -ieq $existing })) { $roots.Add($existing) }
    }
    if ($roots | Where-Object { $_ -ieq $trimmed }) { return }

    $roots.Add($trimmed)
    while ($roots.Count -gt 8) { $roots.RemoveAt(0) }
    $script:Settings.searchRoots = @($roots)
    Save-Settings
}

function Add-RecentProject {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    $recent = New-Object System.Collections.Generic.List[string]
    $recent.Add($Path)
    foreach ($existing in @($script:Settings.recentProjects)) {
        if ($existing -and -not ($recent | Where-Object { $_ -ieq $existing })) { $recent.Add($existing) }
    }
    while ($recent.Count -gt 10) { $recent.RemoveAt($recent.Count - 1) }
    $script:Settings.recentProjects = @($recent)
    Save-Settings
}

function Find-AllWpilibProjects {
    # Nothing here depends on where the launcher itself sits. Projects are found
    # from remembered locations first, so the .exe can live anywhere - a tools
    # folder, the Desktop, a USB stick - and still open the right projects.
    $found = New-Object System.Collections.Generic.List[string]
    $addProject = {
        param([string]$Candidate)
        if ($Candidate -and -not ($found | Where-Object { $_ -ieq $Candidate })) {
            $found.Add($Candidate)
        }
    }

    # 1. Projects opened before, if they are still there.
    foreach ($recent in @($script:Settings.recentProjects)) {
        if (Test-IsWpilibProject $recent) { & $addProject $recent }
    }

    # 2. Folders known to hold projects, learned whenever one is opened.
    foreach ($root in @($script:Settings.searchRoots)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($project in (Find-WpilibProjects -StartDir $root -MaxDepth 2)) {
            & $addProject $project
        }
    }

    # 3. The launcher's own folder and the one above it, which covers the common
    #    case of a fresh copy dropped next to the projects.
    $nearby = New-Object System.Collections.Generic.List[string]
    $nearby.Add($script:ScriptDir)
    $parent = Split-Path -Parent $script:ScriptDir
    if ($parent -and (Test-Path -LiteralPath $parent) -and ($parent -notmatch '^[A-Za-z]:\\?$')) {
        $nearby.Add($parent)
    }
    foreach ($root in $nearby) {
        foreach ($project in (Find-WpilibProjects -StartDir $root -MaxDepth 2)) {
            & $addProject $project
        }
    }

    return @($found)
}

function Select-Project {
    param([string[]]$Candidates, [switch]$AllowBrowse)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Select robot project"
    $dialog.StartPosition = "CenterScreen"
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $dialog.ClientSize = New-Object System.Drawing.Size(680, 380)
    $dialog.MinimizeBox = $false
    Set-DialogIcon $dialog

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Which robot project should this launcher manage?"
    $label.Location = New-Object System.Drawing.Point(14, 12)
    $label.Size = New-Object System.Drawing.Size(650, 20)
    $dialog.Controls.Add($label)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(14, 38)
    $list.Size = New-Object System.Drawing.Size(650, 250)
    $list.Font = New-Object System.Drawing.Font("Consolas", 9)
    foreach ($candidate in $Candidates) { [void]$list.Items.Add($candidate) }
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
    $dialog.Controls.Add($list)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = ("A project is a folder containing both gradlew.bat and build.gradle. " +
                  "Use Search a Folder to point at where your projects are kept.")
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $hint.Location = New-Object System.Drawing.Point(14, 294)
    $hint.Size = New-Object System.Drawing.Size(650, 32)
    $dialog.Controls.Add($hint)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "Use This Project"
    $ok.Size = New-Object System.Drawing.Size(130, 30)
    $ok.Location = New-Object System.Drawing.Point(400, 330)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Enabled = ($list.Items.Count -gt 0)
    $dialog.Controls.Add($ok)

    $browse = New-Object System.Windows.Forms.Button
    $browse.Text = "Browse..."
    $browse.Size = New-Object System.Drawing.Size(100, 30)
    $browse.Location = New-Object System.Drawing.Point(14, 330)
    $dialog.Controls.Add($browse)

    $addRoot = New-Object System.Windows.Forms.Button
    $addRoot.Text = "Search a Folder..."
    $addRoot.Size = New-Object System.Drawing.Size(130, 30)
    $addRoot.Location = New-Object System.Drawing.Point(120, 330)
    $dialog.Controls.Add($addRoot)

    # Points the launcher at a folder that holds projects, rather than at one
    # project. This is what makes the .exe usable from anywhere on a new machine.
    $addRoot.Add_Click({
        $picker = New-Object System.Windows.Forms.FolderBrowserDialog
        $picker.Description = "Select the folder that contains your robot projects"
        if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Add-SearchRoot $picker.SelectedPath
            $rescanned = @(Find-AllWpilibProjects)
            $list.Items.Clear()
            foreach ($candidate in $rescanned) { [void]$list.Items.Add($candidate) }
            if ($list.Items.Count -gt 0) {
                $list.SelectedIndex = 0
                $ok.Enabled = $true
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    $dialog,
                    "No robot projects were found in or under:`r`n$($picker.SelectedPath)",
                    "Nothing found",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            }
        }
        $picker.Dispose()
    })

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancel"
    $cancel.Size = New-Object System.Drawing.Size(100, 30)
    $cancel.Location = New-Object System.Drawing.Point(540, 330)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)

    $script:BrowsedPath = $null
    $browse.Add_Click({
        $picker = New-Object System.Windows.Forms.FolderBrowserDialog
        $picker.Description = "Select the robot project folder (the one with gradlew.bat)"
        if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            if (Test-IsWpilibProject $picker.SelectedPath) {
                $script:BrowsedPath = $picker.SelectedPath
                $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $dialog.Close()
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    $dialog,
                    "That folder does not contain gradlew.bat and build.gradle.",
                    "Not a robot project",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
            }
        }
        $picker.Dispose()
    })

    $list.Add_DoubleClick({
        if ($null -ne $list.SelectedItem) {
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
    })

    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel

    try {
        $result = $dialog.ShowDialog()
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        if ($script:BrowsedPath) { return $script:BrowsedPath }
        return [string]$list.SelectedItem
    }
    finally {
        $dialog.Dispose()
    }
}

function Read-WpilibPreferences {
    $script:TeamNumber = $null
    $script:ProjectYear = $null
    if (-not $script:ProjectRoot) { return }

    $path = Join-Path $script:ProjectRoot ".wpilib\wpilib_preferences.json"
    if (-not (Test-Path -LiteralPath $path)) { return }

    try {
        $prefs = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($null -ne $prefs.teamNumber) {
            $parsed = 0
            if ([int]::TryParse([string]$prefs.teamNumber, [ref]$parsed) -and $parsed -gt 0) {
                $script:TeamNumber = $parsed
            }
        }
        if ($prefs.projectYear) { $script:ProjectYear = [string]$prefs.projectYear }
    }
    catch {
        Append-Log "Could not read .wpilib\wpilib_preferences.json: $($_.Exception.Message)`r`n"
    }
}

function Set-ActiveProject {
    param([string]$Path)

    $script:ProjectRoot = (Resolve-Path -LiteralPath $Path).Path
    $script:JdkPath = $null
    $script:JdkMajor = 0
    $script:JdkChecked = $false
    $script:RepoState = $null

    # Read preferences first: JDK selection depends on the project year.
    Read-WpilibPreferences

    $script:Settings.lastProject = $script:ProjectRoot
    Save-Settings

    # Remember the project, and the folder it lives in. That folder is almost
    # always where the rest of the team's projects are, so after opening one
    # project the launcher can find its siblings from anywhere on the machine.
    Add-RecentProject $script:ProjectRoot
    Add-SearchRoot (Split-Path -Parent $script:ProjectRoot)

    if ($null -ne $lblProject) {
        $lblProject.Text = $script:ProjectRoot
    }
    if ($null -ne $form) {
        $leaf = Split-Path -Leaf $script:ProjectRoot
        $form.Text = "RCM - $leaf"
    }
}

function Resolve-StartupProject {
    # 1. An explicit path passed on the command line wins over everything.
    if (-not [string]::IsNullOrWhiteSpace($Project)) {
        $requested = $Project.Trim().Trim('"')
        if (Test-IsWpilibProject $requested) {
            return (Resolve-Path -LiteralPath $requested).Path
        }
        Append-Log "The folder passed on the command line is not a robot project: $requested`r`n"
    }

    # 2. A project in the launcher's own folder.
    if (Test-IsWpilibProject $script:ScriptDir) { return $script:ScriptDir }

    # 3. The project used last, if it is still there.
    if ($script:Settings.lastProject -and (Test-IsWpilibProject $script:Settings.lastProject)) {
        return $script:Settings.lastProject
    }

    # 4. Everything known or nearby, then ask.
    $candidates = @(Find-AllWpilibProjects)
    if ($candidates.Count -eq 1) { return $candidates[0] }
    return (Select-Project -Candidates $candidates -AllowBrowse)
}

# ---------------- JDK detection ----------------

function Get-JavaMajorVersion {
    param([string]$JavaHome)

    $exe = Join-Path $JavaHome "bin\java.exe"
    if (-not (Test-Path -LiteralPath $exe)) { return 0 }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = "-version"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        # java -version writes to stderr.
        $text = $proc.StandardError.ReadToEnd() + $proc.StandardOutput.ReadToEnd()
        if (-not $proc.WaitForExit(10000)) {
            try { $proc.Kill() } catch { }
            return 0
        }
        $proc.Dispose()

        if ($text -match 'version "([^"]+)"') {
            $version = $Matches[1]
            if ($version.StartsWith("1.")) { $version = $version.Substring(2) }
            if ($version -match '^(\d+)') { return [int]$Matches[1] }
        }
    }
    catch { }

    return 0
}

function Get-MinJavaMajor {
    if ($script:ProjectYear -and $script:MinJavaByYear.ContainsKey($script:ProjectYear)) {
        return $script:MinJavaByYear[$script:ProjectYear]
    }
    # Unknown future season: assume the newest requirement we know about.
    $parsedYear = 0
    if ($script:ProjectYear -and [int]::TryParse($script:ProjectYear, [ref]$parsedYear) -and $parsedYear -ge 2027) {
        return 25
    }
    return $script:DefaultMinJava
}

function Resolve-JdkPath {
    # Mirrors vscode-wpilib findJdkPath: prefer the WPILib JDK for the
    # project's year, then fall back to the usual environment variables.
    if ($script:JdkChecked) { return $script:JdkPath }
    $script:JdkChecked = $true

    $minJava = Get-MinJavaMajor

    $candidates = New-Object System.Collections.Generic.List[PSObject]

    $years = New-Object System.Collections.Generic.List[string]
    if ($script:ProjectYear) { $years.Add($script:ProjectYear) }
    $wpilibRoot = Join-Path $env:PUBLIC "wpilib"
    if (Test-Path -LiteralPath $wpilibRoot) {
        # Newest install first, so a missing projectYear still finds something.
        $installed = @(Get-ChildItem -LiteralPath $wpilibRoot -Directory -ErrorAction SilentlyContinue |
                       Sort-Object Name -Descending | ForEach-Object { $_.Name })
        foreach ($year in $installed) { if (-not $years.Contains($year)) { $years.Add($year) } }
    }
    foreach ($year in $years) {
        $candidates.Add([PSCustomObject]@{
            Path = Join-Path $wpilibRoot "$year\jdk"
            Source = "WPILib $year JDK"
        })
    }

    if ($env:JAVA_HOME) {
        $candidates.Add([PSCustomObject]@{ Path = $env:JAVA_HOME; Source = "JAVA_HOME" })
    }
    if ($env:JDK_HOME) {
        $candidates.Add([PSCustomObject]@{ Path = $env:JDK_HOME; Source = "JDK_HOME" })
    }

    # Take the first candidate new enough for this season; otherwise keep the
    # newest usable JDK found and warn about it.
    $fallback = $null
    foreach ($candidate in $candidates) {
        $path = $candidate.Path.TrimEnd('\', '/')
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $major = Get-JavaMajorVersion $path
        if ($major -ge $minJava) {
            Append-Log "Using JDK $major from $($candidate.Source): $path`r`n"
            $script:JdkPath = $path
            $script:JdkMajor = $major
            return $script:JdkPath
        }
        if ($major -gt 0 -and ($null -eq $fallback -or $major -gt $fallback.Major)) {
            $fallback = [PSCustomObject]@{ Path = $path; Major = $major; Source = $candidate.Source }
        }
    }

    if ($null -ne $fallback) {
        Append-Log ("WARNING: the newest JDK found is Java $($fallback.Major) ($($fallback.Source): " +
                    "$($fallback.Path)), but WPILib $($script:ProjectYear) needs Java $minJava. " +
                    "Builds may fail.`r`n")
        $script:JdkPath = $fallback.Path
        $script:JdkMajor = $fallback.Major
        return $script:JdkPath
    }

    Append-Log "WARNING: no JDK was found. Gradle will fall back to whatever java is on PATH.`r`n"
    return $null
}

# ---------------- Process execution ----------------

function Invoke-Process {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$RawArguments,          # verbatim command line, used for cmd.exe
        [hashtable]$Environment,
        [int]$TimeoutSeconds = 0,       # 0 = no timeout
        [switch]$AllowFailure,
        [switch]$Cancellable,
        [switch]$TrackGradleTasks,      # drive the progress bar from "> Task :" lines
        [int]$ExpectedTaskCount = 0,
        [string]$ProgressLabel = ""
    )

    $argumentLine = if ($PSBoundParameters.ContainsKey('RawArguments')) {
        $RawArguments
    } else {
        ($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' '
    }

    Append-Log "`r`n> $FilePath $argumentLine`r`n"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $argumentLine
    $psi.WorkingDirectory = $script:ProjectRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true      # so a prompting child gets EOF, not a hang
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    # Never let a child block on an interactive prompt: there is no console
    # attached, so a credential prompt would hang the GUI forever.
    $psi.EnvironmentVariables["GIT_TERMINAL_PROMPT"] = "0"
    $psi.EnvironmentVariables["GCM_INTERACTIVE"] = "Never"
    if ($Environment) {
        foreach ($key in $Environment.Keys) {
            $psi.EnvironmentVariables[$key] = [string]$Environment[$key]
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    $stdout = New-Object System.Text.StringBuilder
    $stderr = New-Object System.Text.StringBuilder
    $timedOut = $false
    $cancelled = $false
    $tasksSeen = 0

    try {
        if (-not $process.Start()) { throw "Could not start $FilePath." }

        $process.StandardInput.Close()

        if ($Cancellable) {
            $script:CurrentProcess = $process
            $script:CancelRequested = $false
            if ($null -ne $btnCancel) { $btnCancel.Enabled = $true }
        }

        $started = [System.Diagnostics.Stopwatch]::StartNew()

        # Both streams are polled from this thread. Register-ObjectEvent action
        # blocks run in a separate runspace where these StringBuilders and the
        # form are not visible, which silently discarded all output.
        $outTask = $process.StandardOutput.ReadLineAsync()
        $errTask = $process.StandardError.ReadLineAsync()
        $idleAfterExit = 0

        while (($null -ne $outTask) -or ($null -ne $errTask)) {
            $readAny = $false

            if (($null -ne $outTask) -and $outTask.IsCompleted) {
                if ($outTask.IsFaulted -or $outTask.IsCanceled) {
                    $outTask = $null
                } else {
                    $line = $outTask.Result
                    if ($null -eq $line) {
                        $outTask = $null
                    } else {
                        [void]$stdout.AppendLine($line)
                        Append-Log ($line + "`r`n")
                        if ($TrackGradleTasks -and ($line -match '^> Task :')) {
                            $tasksSeen++
                            Update-BuildProgress -TasksSeen $tasksSeen `
                                                 -Expected $ExpectedTaskCount `
                                                 -Label $ProgressLabel
                        }
                        $outTask = $process.StandardOutput.ReadLineAsync()
                        $readAny = $true
                    }
                }
            }

            if (($null -ne $errTask) -and $errTask.IsCompleted) {
                if ($errTask.IsFaulted -or $errTask.IsCanceled) {
                    $errTask = $null
                } else {
                    $line = $errTask.Result
                    if ($null -eq $line) {
                        $errTask = $null
                    } else {
                        [void]$stderr.AppendLine($line)
                        Append-Log ($line + "`r`n")
                        $errTask = $process.StandardError.ReadLineAsync()
                        $readAny = $true
                    }
                }
            }

            if ($script:CancelRequested -and -not $process.HasExited) {
                $cancelled = $true
                Append-Log "`r`nCancelling...`r`n"
                Stop-ProcessTree $process
                break
            }

            if (($TimeoutSeconds -gt 0) -and ($started.Elapsed.TotalSeconds -gt $TimeoutSeconds) -and
                (-not $process.HasExited)) {
                $timedOut = $true
                Append-Log "`r`nTimed out after $TimeoutSeconds seconds. Stopping.`r`n"
                Stop-ProcessTree $process
                break
            }

            # A lingering grandchild (the Gradle daemon) can inherit the pipe and
            # hold it open, so stop draining shortly after the process exits.
            if ($readAny) {
                $idleAfterExit = 0
            } elseif ($process.HasExited) {
                $idleAfterExit++
                if ($idleAfterExit -gt 40) { break }
            }

            [System.Windows.Forms.Application]::DoEvents()
            if (-not $readAny) { Start-Sleep -Milliseconds 25 }
        }

        $process.WaitForExit(5000) | Out-Null

        $exitCode = if ($process.HasExited) { $process.ExitCode } else { -1 }

        $result = [PSCustomObject]@{
            ExitCode  = $exitCode
            StdOut    = $stdout.ToString().TrimEnd()
            StdErr    = $stderr.ToString().TrimEnd()
            TimedOut  = $timedOut
            Cancelled = $cancelled
            TaskCount = $tasksSeen
            Command   = "$FilePath $argumentLine"
        }

        if (($exitCode -ne 0) -and -not $AllowFailure) {
            throw "$FilePath exited with code $exitCode."
        }

        return $result
    }
    finally {
        if ($Cancellable) {
            $script:CurrentProcess = $null
            $script:CancelRequested = $false
            if ($null -ne $btnCancel) { $btnCancel.Enabled = $false }
        }
        $process.Dispose()
    }
}

function Stop-ProcessTree {
    param([System.Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    try {
        # taskkill /T also gets the Gradle daemon and the deploy ssh session.
        Start-Process -FilePath "taskkill.exe" `
                      -ArgumentList @("/PID", $Process.Id, "/T", "/F") `
                      -WindowStyle Hidden -Wait -ErrorAction Stop
    }
    catch {
        try { $Process.Kill() } catch { }
    }
}

function Test-CommandExists {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# ---------------- Git ----------------

function Invoke-Git {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$Quiet,
        [int]$TimeoutSeconds = 0
    )

    if (-not $Quiet) {
        return Invoke-Process -FilePath "git.exe" -Arguments $Arguments `
                              -AllowFailure:$AllowFailure -TimeoutSeconds $TimeoutSeconds -Cancellable
    }

    # Quiet reads bypass the log and the UI pump: they are short and frequent.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git.exe"
    $psi.Arguments = ($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' '
    $psi.WorkingDirectory = $script:ProjectRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables["GIT_TERMINAL_PROMPT"] = "0"
    $psi.EnvironmentVariables["GCM_INTERACTIVE"] = "Never"

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        [void]$p.Start()
        # Read both streams before waiting so a full pipe cannot deadlock.
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        # Most of these calls finish in a few tens of milliseconds, so wait
        # briefly without pumping messages first: that keeps the common case
        # free of re-entrancy. Only a genuinely slow call starts pumping, which
        # is what keeps the activity bar moving.
        if (-not $p.WaitForExit(120)) {
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            while ((-not $p.HasExited) -and ($clock.Elapsed.TotalSeconds -lt 20)) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 15
            }
        }

        if (-not $p.HasExited) {
            Stop-ProcessTree $p
            if (-not $AllowFailure) { throw "git $($Arguments -join ' ') timed out." }
            return [PSCustomObject]@{ ExitCode = -1; StdOut = ""; StdErr = "timed out" }
        }
        $p.WaitForExit()   # lets the async stream reads complete
        $stdout = $outTask.Result
        $stderr = $errTask.Result
        if (($p.ExitCode -ne 0) -and -not $AllowFailure) {
            throw "git $($Arguments -join ' ') failed: $stderr"
        }
        return [PSCustomObject]@{
            ExitCode = $p.ExitCode
            StdOut   = $stdout.TrimEnd()
            StdErr   = $stderr.TrimEnd()
        }
    }
    finally {
        $p.Dispose()
    }
}

function Test-GitPath {
    param([string]$RelativePath)
    # git rev-parse --git-path is correct for worktrees and submodules, where
    # .git is a file rather than a directory.
    $result = Invoke-Git @("rev-parse", "--git-path", $RelativePath) -AllowFailure -Quiet
    if ($result.ExitCode -ne 0) { return $false }
    $path = $result.StdOut.Trim()
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Join-Path $script:ProjectRoot $path
    }
    return Test-Path -LiteralPath $path
}

function New-EmptyRepoState {
    param([string]$Reason)
    return [PSCustomObject]@{
        IsRepo = $false; Reason = $Reason
        Branch = "(not a Git repository)"; Detached = $false; HasCommits = $false
        Head = "-"; HeadFull = ""; Dirty = $false; ChangedCount = 0
        StatusLines = @(); ConflictCount = 0
        HasUpstream = $false; Upstream = "(none)"; Ahead = 0; Behind = 0
        LocalCommits = ""; IncomingCommits = ""; OutgoingCommits = ""
        MergeInProgress = $false; RebaseInProgress = $false
    }
}

function Get-RepositoryState {
    if (-not (Test-CommandExists "git.exe")) {
        return (New-EmptyRepoState "git was not found on PATH")
    }

    $inside = Invoke-Git @("rev-parse", "--is-inside-work-tree") -AllowFailure -Quiet
    if (($inside.ExitCode -ne 0) -or ($inside.StdOut.Trim() -ne "true")) {
        return (New-EmptyRepoState "this project folder is not inside a Git repository")
    }

    $branchResult = Invoke-Git @("branch", "--show-current") -AllowFailure -Quiet
    $branch = $branchResult.StdOut.Trim()
    $detached = [string]::IsNullOrWhiteSpace($branch)
    if ($detached) { $branch = "(detached HEAD)" }

    # A repository with no commits yet has no HEAD to resolve.
    $headResult = Invoke-Git @("rev-parse", "--short=8", "HEAD") -AllowFailure -Quiet
    $hasCommits = $headResult.ExitCode -eq 0
    $head = if ($hasCommits) { $headResult.StdOut.Trim() } else { "(no commits yet)" }
    $headFull = if ($hasCommits) { (Invoke-Git @("rev-parse", "HEAD") -AllowFailure -Quiet).StdOut.Trim() } else { "" }

    $statusLines = @()
    # core.quotePath=false stops git escaping non-ASCII paths as "caf\303\251.txt",
    # which would never resolve back to a real file on disk.
    $statusResult = Invoke-Git @("-c", "core.quotePath=false", "status", "--porcelain=v1") -AllowFailure -Quiet
    if ($statusResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($statusResult.StdOut)) {
        $statusLines = @($statusResult.StdOut -split "`r?`n" | Where-Object { $_ -ne "" })
    }

    $conflicts = @($statusLines | Where-Object { $_ -match '^(UU|AA|DD|AU|UA|DU|UD)' })

    $upstreamResult = Invoke-Git @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}") -AllowFailure -Quiet
    $hasUpstream = $upstreamResult.ExitCode -eq 0
    $upstream = if ($hasUpstream) { $upstreamResult.StdOut.Trim() } else { "(none)" }

    $ahead = 0
    $behind = 0
    if ($hasUpstream) {
        $counts = Invoke-Git @("rev-list", "--left-right", "--count", "HEAD...@{upstream}") -AllowFailure -Quiet
        if ($counts.ExitCode -eq 0 -and $counts.StdOut -match '^\s*(\d+)\s+(\d+)\s*$') {
            $ahead = [int]$Matches[1]
            $behind = [int]$Matches[2]
        }
    }

    $localCommits = ""
    if ($hasCommits) {
        $localCommits = (Invoke-Git @(
            "log", "--max-count=15", "--pretty=format:%h`t%ad`t%an`t%s", "--date=short", "HEAD"
        ) -AllowFailure -Quiet).StdOut
    }

    $incoming = ""
    if ($hasUpstream -and $behind -gt 0) {
        $incoming = (Invoke-Git @(
            "log", "--max-count=15", "--pretty=format:%h`t%ad`t%an`t%s", "--date=short", "HEAD..@{upstream}"
        ) -AllowFailure -Quiet).StdOut
    }

    $outgoing = ""
    if ($hasUpstream -and $ahead -gt 0) {
        $outgoing = (Invoke-Git @(
            "log", "--max-count=15", "--pretty=format:%h`t%ad`t%an`t%s", "--date=short", "@{upstream}..HEAD"
        ) -AllowFailure -Quiet).StdOut
    }

    return [PSCustomObject]@{
        IsRepo = $true
        Reason = ""
        Branch = $branch
        Detached = $detached
        HasCommits = $hasCommits
        Head = $head
        HeadFull = $headFull
        Dirty = $statusLines.Count -gt 0
        ChangedCount = $statusLines.Count
        StatusLines = $statusLines
        ConflictCount = $conflicts.Count
        HasUpstream = $hasUpstream
        Upstream = $upstream
        Ahead = $ahead
        Behind = $behind
        LocalCommits = $localCommits
        IncomingCommits = $incoming
        OutgoingCommits = $outgoing
        MergeInProgress = (Test-GitPath "MERGE_HEAD")
        RebaseInProgress = (Test-GitPath "rebase-merge") -or (Test-GitPath "rebase-apply")
    }
}

function Ensure-GitIdentity {
    $name = (Invoke-Git @("config", "user.name") -AllowFailure -Quiet).StdOut.Trim()
    $email = (Invoke-Git @("config", "user.email") -AllowFailure -Quiet).StdOut.Trim()
    if ($name -and $email) { return $true }

    Show-Info ("Git does not know who you are yet, so it cannot record a commit.`r`n`r`n" +
               "You will be asked for a name and an email. These are stored for this " +
               "project only and appear next to your commits.")

    if (-not $name) {
        $name = Show-InputDialog -Prompt "Your name (shown as the commit author):" -Title "Git identity"
        if ([string]::IsNullOrWhiteSpace($name)) { return $false }
        Invoke-Git @("config", "--local", "user.name", $name.Trim()) -AllowFailure -Quiet | Out-Null
    }
    if (-not $email) {
        $email = Show-InputDialog -Prompt "Your email:" -Title "Git identity"
        if ([string]::IsNullOrWhiteSpace($email)) { return $false }
        Invoke-Git @("config", "--local", "user.email", $email.Trim()) -AllowFailure -Quiet | Out-Null
    }
    return $true
}

# ---------------- UI state ----------------

function Set-Busy {
    param([bool]$Busy, [string]$Message = "")
    $script:IsBusy = $Busy
    foreach ($control in $actionButtons) { $control.Enabled = -not $Busy }
    Set-ActivityIndicator $Busy
    if ($Message) {
        $lblOperation.Text = $Message
    } elseif (-not $Busy) {
        $lblOperation.Text = "Ready"
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Add-CommitRows {
    param([System.Windows.Forms.ListView]$ListView, [string]$Text)
    $ListView.BeginUpdate()
    try {
        $ListView.Items.Clear()
        if ([string]::IsNullOrWhiteSpace($Text)) {
            [void]$ListView.Items.Add((New-Object System.Windows.Forms.ListViewItem("(none)")))
            return
        }
        foreach ($line in ($Text -split "`r?`n")) {
            $parts = $line -split "`t", 4
            if ($parts.Count -lt 4) { continue }
            $item = New-Object System.Windows.Forms.ListViewItem($parts[0])
            [void]$item.SubItems.Add($parts[1])
            [void]$item.SubItems.Add($parts[2])
            [void]$item.SubItems.Add($parts[3])
            [void]$ListView.Items.Add($item)
        }
    }
    finally {
        $ListView.EndUpdate()
    }
}

function Update-StateDisplay {
    param($State)
    if ($null -eq $State) { return }
    if (-not $script:UiReady) { return }

    $lblBranchValue.Text = $State.Branch
    $lblCommitValue.Text = $State.Head
    $lblUpstreamValue.Text = $State.Upstream
    $lblTeamValue.Text = if ($script:TeamNumber) { [string]$script:TeamNumber } else { "(unknown)" }

    if (-not $State.IsRepo) {
        $lblWorkingValue.Text = "n/a"
        $lblWorkingValue.ForeColor = [System.Drawing.Color]::DimGray
    } elseif ($State.Dirty) {
        $lblWorkingValue.Text = "$($State.ChangedCount) changed file(s)"
        $lblWorkingValue.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $lblWorkingValue.Text = "Clean"
        $lblWorkingValue.ForeColor = [System.Drawing.Color]::DarkGreen
    }

    $lblSyncValue.Text = "Ahead $($State.Ahead)  |  Behind $($State.Behind)"
    if ($State.Ahead -gt 0 -or $State.Behind -gt 0) {
        $lblSyncValue.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $lblSyncValue.ForeColor = [System.Drawing.Color]::DarkGreen
    }

    $warnings = New-Object System.Collections.Generic.List[string]
    if (-not $State.IsRepo) {
        $warnings.Add("Not under Git: $($State.Reason).")
        $warnings.Add("Build and deploy still work, but nothing is version controlled or backed up.")
    } else {
        if ($State.Detached) { $warnings.Add("Detached HEAD: you are not currently on a branch.") }
        if (-not $State.HasUpstream) { $warnings.Add("No upstream branch is configured, so nothing can be pushed or pulled.") }
        if ($State.ConflictCount -gt 0) { $warnings.Add("$($State.ConflictCount) unresolved merge conflict(s).") }
        if ($State.MergeInProgress) { $warnings.Add("A merge is currently in progress.") }
        if ($State.RebaseInProgress) { $warnings.Add("A rebase is currently in progress.") }
        if ($State.Dirty) { $warnings.Add("$($State.ChangedCount) local file(s) are modified or untracked.") }
        if ($State.Ahead -gt 0) { $warnings.Add("$($State.Ahead) local commit(s) have not been pushed.") }
        if ($State.Behind -gt 0) { $warnings.Add("$($State.Behind) remote commit(s) are not on this computer.") }
        if ($State.Ahead -gt 0 -and $State.Behind -gt 0) { $warnings.Add("The branch has diverged. Do not blindly pull.") }
    }
    if (-not $script:TeamNumber) {
        $warnings.Add("No team number found in .wpilib\wpilib_preferences.json; deploy may not find the robot.")
    }

    if ($warnings.Count -eq 0) {
        $txtWarnings.Text = "Repository is clean and synchronized."
        $txtWarnings.ForeColor = [System.Drawing.Color]::DarkGreen
    } else {
        $txtWarnings.Text = ($warnings | ForEach-Object { "* $_" }) -join "`r`n"
        $txtWarnings.ForeColor = [System.Drawing.Color]::DarkRed
    }

    $txtFiles.Text = if ($State.StatusLines.Count) {
        ($State.StatusLines -join "`r`n")
    } else {
        "(no changed files)"
    }

    Add-CommitRows -ListView $listRecent -Text $State.LocalCommits
    Add-CommitRows -ListView $listIncoming -Text $State.IncomingCommits
    Add-CommitRows -ListView $listOutgoing -Text $State.OutgoingCommits

    $free = -not $script:IsBusy
    $gitOk = $free -and $State.IsRepo

    $btnCommit.Enabled = $gitOk -and $State.Dirty -and ($State.ConflictCount -eq 0) -and
                         (-not $State.MergeInProgress) -and (-not $State.RebaseInProgress)

    $btnPull.Enabled = $gitOk -and $State.HasUpstream -and (-not $State.Dirty) -and
                       ($State.Behind -gt 0) -and ($State.Ahead -eq 0) -and
                       ($State.ConflictCount -eq 0) -and (-not $State.MergeInProgress) -and
                       (-not $State.RebaseInProgress)

    $btnPush.Enabled = $gitOk -and $State.HasUpstream -and ($State.Ahead -gt 0) -and
                       ($State.Behind -eq 0) -and ($State.ConflictCount -eq 0)

    $btnDiff.Enabled = $gitOk

    # Left enabled while dirty on purpose: clicking it then explains exactly why
    # it will not switch, which teaches more than a dead button.
    $btnBranch.Enabled = $gitOk -and $State.HasCommits

    # A diff left open after a commit would still show the old changes.
    if (($null -ne $diffSplit) -and (-not $diffSplit.Panel1Collapsed) -and (-not $State.Dirty)) {
        $script:DiffFiles = @()
        $script:DiffPopulating = $true
        $cmbDiffFile.Items.Clear()
        $script:DiffPopulating = $false
        Render-Diff
    }

    $blockedByGit = $State.IsRepo -and
                    (($State.ConflictCount -gt 0) -or $State.MergeInProgress -or $State.RebaseInProgress)
    $btnDeploy.Enabled = $free -and (-not $blockedByGit)
    $btnBuild.Enabled = $free -and (-not $blockedByGit)
}

function Refresh-Repository {
    param([switch]$Fetch)

    if ($script:IsBusy) { return }
    Set-Busy $true $(if ($Fetch) { "Fetching from GitHub..." } else { "Reading repository..." })
    try {
        if ($Fetch) {
            $probe = Invoke-Git @("rev-parse", "--is-inside-work-tree") -AllowFailure -Quiet
            if ($probe.ExitCode -eq 0 -and $probe.StdOut.Trim() -eq "true") {
                # A dead network at a competition must not wedge the launcher.
                $fetchResult = Invoke-Git @("fetch", "--prune") -AllowFailure -TimeoutSeconds 30
                if ($fetchResult.TimedOut) {
                    Append-Log "`r`nFetch timed out (no network?). Showing local information only.`r`n"
                } elseif ($fetchResult.ExitCode -ne 0) {
                    Append-Log "`r`nFetch failed. Showing local information only.`r`n"
                }
            }
        }

        $script:RepoState = Get-RepositoryState
        Append-Log "`r`nRepository status refreshed.`r`n"
    }
    catch {
        Append-Log "`r`nERROR: $($_.Exception.Message)`r`n"
        if ($null -eq $script:RepoState) {
            $script:RepoState = New-EmptyRepoState $_.Exception.Message
        }
    }
    finally {
        Set-Busy $false
        Update-StateDisplay $script:RepoState
    }
}

# ---------------- Robot connectivity ----------------

function Get-RobotAddresses {
    if (-not $script:TeamNumber) { return @() }
    $team = [int]$script:TeamNumber
    $high = [math]::Floor($team / 100)
    $low = $team % 100
    return @(
        [PSCustomObject]@{ Address = "roborio-$team-FRC.local"; Label = "mDNS (radio or USB)" }
        [PSCustomObject]@{ Address = "10.$high.$low.2";         Label = "Static team IP" }
        [PSCustomObject]@{ Address = "172.22.11.2";             Label = "USB" }
    )
}

function Test-RobotAddresses {
    # A roboRIO on the robot network replies in well under 100 ms, so the caps
    # only govern how fast a *failure* is reported.
    param([int]$TimeoutMs = 1200, [int]$OverallMs = 2500)

    # All addresses are probed at once. Probing them one at a time took about
    # seven seconds to report failure, because an unresolvable .local name
    # blocks for several seconds on its own.
    $probes = New-Object System.Collections.Generic.List[PSObject]
    foreach ($candidate in (Get-RobotAddresses)) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $task = $null
        try { $task = $ping.SendPingAsync($candidate.Address, $TimeoutMs) } catch { }
        $probes.Add([PSCustomObject]@{ Candidate = $candidate; Ping = $ping; Task = $task })
    }

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while ($clock.Elapsed.TotalMilliseconds -lt $OverallMs) {
            $pending = @($probes | Where-Object { $null -ne $_.Task -and -not $_.Task.IsCompleted })
            if ($pending.Count -eq 0) { break }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }

        $results = New-Object System.Collections.Generic.List[PSObject]
        foreach ($probe in $probes) {
            $reachable = $false
            if (($null -ne $probe.Task) -and $probe.Task.IsCompleted -and
                (-not $probe.Task.IsFaulted) -and (-not $probe.Task.IsCanceled)) {
                $reachable = $probe.Task.Result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success
            }
            $results.Add([PSCustomObject]@{
                Address   = $probe.Candidate.Address
                Label     = $probe.Candidate.Label
                Reachable = $reachable
            })
        }
        return $results
    }
    finally {
        foreach ($probe in $probes) { try { $probe.Ping.Dispose() } catch { } }
    }
}

function Find-Robot {
    # Returns the most preferred reachable address, or $null.
    foreach ($result in (Test-RobotAddresses)) {
        if ($result.Reachable) { return $result }
    }
    return $null
}

function Check-RobotConnection {
    if ($script:IsBusy) { return }
    if (-not $script:TeamNumber) {
        Show-Error "No team number is configured, so the robot address cannot be worked out."
        return
    }

    Set-Busy $true "Looking for the robot..."
    try {
        Append-Log "`r`nChecking robot addresses for team $($script:TeamNumber)...`r`n"
        $reachable = New-Object System.Collections.Generic.List[string]
        foreach ($result in (Test-RobotAddresses)) {
            if ($result.Reachable) {
                Append-Log "  reachable: $($result.Address)  [$($result.Label)]`r`n"
                $reachable.Add("$($result.Address)  ($($result.Label))")
            } else {
                Append-Log "  no reply:  $($result.Address)  [$($result.Label)]`r`n"
            }
        }

        if ($reachable.Count -gt 0) {
            Show-Info ("The robot answered on:`r`n`r`n" + ($reachable -join "`r`n"))
        } else {
            Show-Error ("The roboRIO did not answer on any known address.`r`n`r`n" +
                        "Check that the robot is powered on, the radio has finished booting, " +
                        "and this computer is on the robot network or plugged into the USB port.`r`n`r`n" +
                        "Deploy will almost certainly fail until this is fixed.")
        }
    }
    finally {
        Set-Busy $false
        Update-StateDisplay $script:RepoState
    }
}

# ---------------- Gradle ----------------

function Get-GradleArguments {
    param([Parameter(Mandatory=$true)][string]$Task)

    # Argument order follows vscode-wpilib so the command lines are comparable.
    $list = New-Object System.Collections.Generic.List[string]
    $list.Add($Task)

    if ($Task -eq 'deploy') {
        if ($script:TeamNumber) { $list.Add("-PteamNumber=$($script:TeamNumber)") }
        if ($chkSkipTests.Checked) { $list.Add("-xcheck") }
        if ($chkOfflineDeploy.Checked) { $list.Add("--offline") }
    } elseif ($chkOfflineBuild.Checked) {
        $list.Add("--offline")
    }

    $jdk = Resolve-JdkPath
    if ($jdk) { $list.Add("-Dorg.gradle.java.home=`"$jdk`"") }

    # Plain console keeps the captured log free of progress-bar control codes.
    $list.Add("--console=plain")

    return $list.ToArray()
}

function Get-GradleCommandLine {
    param([string]$Task)
    # Run through cmd.exe with a relative gradlew.bat, exactly as the WPILib
    # extension does, so quoting and wrapper behaviour match.
    return "/d /c gradlew.bat " + ((Get-GradleArguments -Task $Task) -join ' ')
}

function Get-DeployWarningText {
    param($State, [string]$CommandLine, $Robot)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("You are about to deploy to the robot.")
    $lines.Add("")
    $lines.Add("Project: $(Split-Path -Leaf $script:ProjectRoot)")
    $lines.Add("Team:    $(if ($script:TeamNumber) { $script:TeamNumber } else { 'unknown' })")
    if ($State.IsRepo) {
        $lines.Add("Branch:  $($State.Branch)")
        $lines.Add("Commit:  $($State.Head)")
        $lines.Add("Changed: $($State.ChangedCount) file(s)    Ahead: $($State.Ahead)    Behind: $($State.Behind)")
    } else {
        $lines.Add("Git:     not a repository")
    }
    $lines.Add("Robot:   $(if ($Robot) { "reachable at $($Robot.Address)" } else { 'NOT REACHABLE' })")
    $lines.Add("")
    $lines.Add("Command: cmd.exe $CommandLine")
    $lines.Add("")

    if (-not $Robot) {
        $lines.Add("WARNING: The roboRIO did not answer a ping. Deploy will probably fail.")
    }
    if ($State.IsRepo) {
        if ($State.Detached) { $lines.Add("WARNING: Detached HEAD.") }
        if ($State.Dirty) { $lines.Add("WARNING: The deployed code includes uncommitted changes.") }
        if ($State.Ahead -gt 0) { $lines.Add("WARNING: Some deployed commits are not backed up on GitHub.") }
        if ($State.Behind -gt 0) { $lines.Add("WARNING: GitHub has newer commits that are not on this computer.") }
        if ($State.Ahead -gt 0 -and $State.Behind -gt 0) { $lines.Add("WARNING: Local and remote history have diverged.") }
        if (-not $State.HasUpstream) { $lines.Add("WARNING: This branch has no upstream tracking branch.") }
    } else {
        $lines.Add("WARNING: This code is not in Git, so this exact version cannot be recovered later.")
    }

    $lines.Add("")
    $lines.Add("Deploy this exact local working copy anyway?")
    return $lines -join "`r`n"
}

function Get-LogDirectory {
    $dir = Join-Path $script:ProjectRoot ".deploy-history"
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    # The deploy log is per-computer. Ignoring the folder from inside it keeps
    # the records out of Git without editing the project's root .gitignore.
    $ignore = Join-Path $dir ".gitignore"
    if (-not (Test-Path -LiteralPath $ignore)) {
        # Written without a BOM: Set-Content -Encoding UTF8 adds one on PS 5.1,
        # and a BOM would become part of the first pattern git reads.
        [System.IO.File]::WriteAllLines(
            $ignore,
            [string[]]@(
                "# Local build and deploy records written by RCM (Robot Code Manager).",
                "# Never shared through Git: each computer keeps its own log.",
                "*"
            ),
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
    return $dir
}

function Write-RunLog {
    param([string]$Task, $Result)
    try {
        $dir = Join-Path (Get-LogDirectory) "logs"
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $stamp = (Get-Date).ToString("yyyy-MM-dd_HH-mm-ss")
        $path = Join-Path $dir "$stamp-$Task.log"
        $content = @(
            "Command : $($Result.Command)",
            "Started : $stamp",
            "ExitCode: $($Result.ExitCode)",
            "",
            "----- output -----",
            $Result.StdOut,
            "",
            "----- errors -----",
            $Result.StdErr
        )
        Set-Content -Path $path -Value $content -Encoding UTF8
        return $path
    }
    catch {
        Append-Log "Could not write the run log: $($_.Exception.Message)`r`n"
        return $null
    }
}

function Write-DeploymentRecord {
    param($State, $Result, [string]$LogPath, $Robot)

    try {
        $record = [PSCustomObject]@{
            timestamp      = (Get-Date).ToString("o")
            computer       = $env:COMPUTERNAME
            user           = $env:USERNAME
            project        = $script:ProjectRoot
            teamNumber     = $script:TeamNumber
            command        = $Result.Command
            robotAddress   = if ($Robot) { $Robot.Address } else { $null }
            isRepo         = $State.IsRepo
            branch         = $State.Branch
            commit         = $State.HeadFull
            shortCommit    = $State.Head
            dirty          = $State.Dirty
            changedFiles   = $State.StatusLines
            upstream       = $State.Upstream
            ahead          = $State.Ahead
            behind         = $State.Behind
            deployExitCode = $Result.ExitCode
            cancelled      = $Result.Cancelled
            logFile        = $LogPath
        }
        $jsonLine = $record | ConvertTo-Json -Compress -Depth 5
        Add-Content -Path (Join-Path (Get-LogDirectory) "deployments.jsonl") -Value $jsonLine -Encoding UTF8
    }
    catch {
        Append-Log "Could not write the deployment record: $($_.Exception.Message)`r`n"
    }
}

function Run-GradleTask {
    param(
        [Parameter(Mandatory=$true)][string]$Task,
        [switch]$Deploy
    )

    if ($script:IsBusy) { return }

    $gradle = Join-Path $script:ProjectRoot "gradlew.bat"
    if (-not (Test-Path -LiteralPath $gradle)) {
        Show-Error ("gradlew.bat was not found in:`r`n$script:ProjectRoot`r`n`r`n" +
                    "Use Change Project to pick a real WPILib project folder.")
        return
    }

    Refresh-Repository -Fetch
    $state = $script:RepoState
    if ($null -eq $state) { return }

    if ($state.IsRepo -and
        ($state.ConflictCount -gt 0 -or $state.MergeInProgress -or $state.RebaseInProgress)) {
        Show-Error "Build and deploy are blocked because Git has unresolved conflicts or an unfinished merge/rebase."
        return
    }

    # Resolve the JDK before the confirmation dialog so its warnings are visible
    # in the log and the exact command can be shown.
    Resolve-JdkPath | Out-Null

    $robot = $null
    if ($Deploy) {
        Set-Busy $true "Looking for the robot..."
        try { $robot = Find-Robot } finally { Set-Busy $false }

        $commandLine = Get-GradleCommandLine -Task $Task
        if (-not (Show-WarningConfirm (Get-DeployWarningText $state $commandLine $robot) "Confirm robot deployment")) {
            Append-Log "`r`nDeployment cancelled.`r`n"
            Update-StateDisplay $state
            return
        }
    }

    Set-Busy $true $(if ($Deploy) { "Deploying robot code..." } else { "Building robot code..." })
    try {
        $jdk = $script:JdkPath
        $environment = @{}
        if ($jdk) { $environment["JAVA_HOME"] = $jdk }

        # Echo the inputs that decide where the code goes, so a wrong team
        # number is visible in the log for builds as well as deploys.
        Append-Log "`r`n--------------------------------------------------------------`r`n"
        Append-Log "Task        : $Task`r`n"
        Append-Log "Project     : $script:ProjectRoot`r`n"
        Append-Log "Team number : $(if ($script:TeamNumber) { $script:TeamNumber } else { 'NOT FOUND' })`r`n"
        Append-Log "JDK         : $(if ($jdk) { "$jdk (Java $($script:JdkMajor))" } else { 'not found; using java from PATH' })`r`n"
        Append-Log "--------------------------------------------------------------`r`n"

        $expected = Get-TaskBaseline -Task $Task
        $progressLabel = if ($Deploy) { "Deploying robot code..." } else { "Building robot code..." }
        Show-BuildProgress $true 1

        $result = Invoke-Process -FilePath $env:ComSpec `
                                 -RawArguments (Get-GradleCommandLine -Task $Task) `
                                 -Environment $environment `
                                 -AllowFailure -Cancellable `
                                 -TrackGradleTasks -ExpectedTaskCount $expected `
                                 -ProgressLabel $progressLabel

        if ($result.ExitCode -eq 0) {
            Show-BuildProgress $true 100
            # Calibrate the next run's estimate from what this one actually did.
            Set-TaskBaseline -Task $Task -Count $result.TaskCount
        }

        $logPath = Write-RunLog -Task $Task -Result $result
        if ($Deploy) {
            Write-DeploymentRecord -State $state -Result $result -LogPath $logPath -Robot $robot
        }

        if ($result.Cancelled) {
            Append-Log "`r`n$Task was cancelled.`r`n"
            Show-Info "$Task was cancelled. The robot may have been left partially updated." "Cancelled"
        }
        elseif ($result.ExitCode -eq 0) {
            $message = if ($Deploy) {
                "Robot deployment completed successfully."
            } else {
                "Robot code build completed successfully."
            }
            Append-Log "`r`nSUCCESS: $message`r`n"
            Show-Info $message "Success"
        }
        else {
            $hint = Get-FailureHint -Task $Task -Result $result -Robot $robot
            $message = "$(if ($Deploy) { 'Deployment' } else { 'Build' }) failed. Exit code: $($result.ExitCode)"
            if ($hint) { $message += "`r`n`r`n$hint" }
            if ($logPath) { $message += "`r`n`r`nFull log: $logPath" }
            Append-Log "`r`nFAILED: $message`r`n"
            Show-Error $message
        }
    }
    catch {
        Append-Log "`r`nERROR: $($_.Exception.Message)`r`n"
        Show-Error $_.Exception.Message
    }
    finally {
        Show-BuildProgress $false 0
        Set-Busy $false
        Refresh-Repository
    }
}

function Get-FailureHint {
    param([string]$Task, $Result, $Robot)

    $text = ($Result.StdOut + "`n" + $Result.StdErr)

    # Dependency failures are tested first on purpose. Gradle words them as
    # "Could not resolve all files for configuration ':roborio'", which reads
    # like a robot problem but is really a download problem, and sending someone
    # to check the radio when the fix is --offline wastes time on the field.
    if ($text -match 'Could not resolve all (files|dependencies)|Could not GET|Connection (refused|timed out)|UnknownHostException|Could not download') {
        if ($Task -eq 'deploy') {
            return ("Gradle tried to download dependencies and failed. Tick 'Offline deploy' " +
                    "so it uses the local WPILib maven cache instead.")
        }
        return ("Gradle tried to download dependencies and failed. Tick 'Offline build' to use " +
                "the local WPILib maven cache, or connect this computer to the internet.")
    }
    if ($text -match 'Are you sure the target is correct|No target found|Missing Target|cannot be reached|Unable to determine.*address|No route to host') {
        if (-not $Robot) {
            return ("The robot was not reachable before this deploy started. " +
                    "Check power, the radio, and your network connection, then use Check Robot.")
        }
        return "GradleRIO could not reach the roboRIO even though it answered a ping. Try again, or reboot the roboRIO."
    }
    if ($text -match 'invalid source release|release version .* not supported|UnsupportedClassVersionError|Unsupported class file major version') {
        $year = if ($script:ProjectYear) { $script:ProjectYear } else { "this season" }
        $found = if ($script:JdkMajor) { "Java $($script:JdkMajor) is being used" } else { "no JDK version was detected" }
        return ("This looks like a Java version problem. WPILib $year needs Java $(Get-MinJavaMajor) " +
                "and $found. Reinstall the WPILib $year tools, or clear a stale JAVA_HOME.")
    }
    if ($text -match "error: |compilation failed|Compilation failed") {
        return "The code did not compile. Scroll up in the output for the first 'error:' line."
    }
    if ($text -match 'Task .* not found|Cannot locate tasks') {
        return "Gradle did not recognise the task. Make sure this is a WPILib GradleRIO project."
    }
    if ($text -match 'test.*FAILED|There were failing tests') {
        return "A unit test failed. Tick 'Skip tests on deploy' to bypass tests when you need to get on the field."
    }
    return $null
}

function Stop-GradleDaemons {
    if ($script:IsBusy) { return }
    if (-not (Show-WarningConfirm ("Stop all background Gradle processes for this project?`r`n`r`n" +
                                   "Use this when builds hang or fail for no clear reason. The next " +
                                   "build will be slower while Gradle starts up again.") "Stop Gradle")) {
        return
    }

    Set-Busy $true "Stopping Gradle daemons..."
    try {
        $jdk = Resolve-JdkPath
        $environment = @{}
        if ($jdk) { $environment["JAVA_HOME"] = $jdk }
        $stopArgs = "/d /c gradlew.bat --stop"
        if ($jdk) { $stopArgs += " -Dorg.gradle.java.home=`"$jdk`"" }
        Invoke-Process -FilePath $env:ComSpec -RawArguments $stopArgs -Environment $environment `
                       -AllowFailure -TimeoutSeconds 60 -Cancellable | Out-Null
        Append-Log "`r`nGradle daemons stopped.`r`n"
    }
    catch {
        Append-Log "`r`nERROR: $($_.Exception.Message)`r`n"
    }
    finally {
        Set-Busy $false
        Update-StateDisplay $script:RepoState
    }
}

# ---------------- Git actions ----------------

function Commit-All {
    Refresh-Repository
    $state = $script:RepoState
    if ($null -eq $state -or -not $state.IsRepo) {
        Show-Error "This project is not in a Git repository, so there is nothing to commit."
        return
    }
    if (-not $state.Dirty) {
        Show-Info "There are no changes to commit."
        return
    }
    if ($state.ConflictCount -gt 0 -or $state.MergeInProgress -or $state.RebaseInProgress) {
        Show-Error "Resolve the conflicts or finish the merge/rebase before committing from here."
        return
    }
    if (-not (Ensure-GitIdentity)) {
        Append-Log "`r`nCommit cancelled: no Git identity was set.`r`n"
        return
    }

    $preview = ($state.StatusLines | Select-Object -First 12) -join "`r`n"
    if ($state.ChangedCount -gt 12) { $preview += "`r`n... and $($state.ChangedCount - 12) more" }

    $message = Show-InputDialog -Multiline -Title "Commit all changes" -Prompt (
        "Describe what changed. All $($state.ChangedCount) file(s) below will be committed:`r`n$preview")
    if ([string]::IsNullOrWhiteSpace($message)) {
        Append-Log "`r`nCommit cancelled.`r`n"
        return
    }

    Set-Busy $true "Committing..."
    try {
        $add = Invoke-Git @("add", "--all") -AllowFailure
        if ($add.ExitCode -ne 0) {
            Show-Error "git add failed. Read the output for details."
            return
        }
        $commit = Invoke-Git @("commit", "-m", $message.Trim()) -AllowFailure
        if ($commit.ExitCode -ne 0) {
            Show-Error "git commit failed. Read the output for details."
        } else {
            Append-Log "`r`nCommit created.`r`n"
        }
    }
    finally {
        Set-Busy $false
        Refresh-Repository
    }
}

function Safe-Pull {
    Refresh-Repository -Fetch
    $s = $script:RepoState
    if ($null -eq $s) { return }
    if (-not $s.IsRepo) { Show-Error "This project is not in a Git repository."; return }
    if (-not $s.HasUpstream) { Show-Error "This branch has no upstream branch to pull from."; return }
    if ($s.Dirty) { Show-Error "Safe pull is blocked because there are uncommitted changes. Commit them first."; return }
    if ($s.Ahead -gt 0 -and $s.Behind -gt 0) {
        Show-Error "The branch has diverged. Resolve this manually instead of using an automatic pull."
        return
    }
    if ($s.Ahead -gt 0) { Show-Error "Safe pull is blocked because this computer has unpushed commits. Push them first."; return }
    if ($s.Behind -eq 0) { Show-Info "There is nothing to pull."; return }

    if (-not (Show-WarningConfirm ("Run git pull --ff-only?`r`n`r`nThis brings in $($s.Behind) commit(s) and " +
                                   "refuses to create a merge commit.") "Safe pull")) {
        return
    }

    Set-Busy $true "Pulling with fast-forward only..."
    try {
        $result = Invoke-Git @("pull", "--ff-only") -AllowFailure -TimeoutSeconds 120
        if ($result.TimedOut) {
            Show-Error "The pull timed out. Check the network connection."
        } elseif ($result.ExitCode -ne 0) {
            Show-Error "Safe pull failed. No automatic merge was performed."
        } else {
            Append-Log "`r`nPull complete.`r`n"
        }
    }
    finally {
        Set-Busy $false
        Refresh-Repository
    }
}

function Push-Commits {
    Refresh-Repository -Fetch
    $s = $script:RepoState
    if ($null -eq $s) { return }
    if (-not $s.IsRepo) { Show-Error "This project is not in a Git repository."; return }
    if (-not $s.HasUpstream) { Show-Error "This branch has no upstream branch. Set one up in VS Code first."; return }
    if ($s.Behind -gt 0) {
        Show-Error "Push is blocked because the remote branch has commits you do not have. Pull first."
        return
    }
    if ($s.Ahead -eq 0) { Show-Info "There are no local commits to push."; return }

    if (-not (Show-WarningConfirm "Push $($s.Ahead) local commit(s) to $($s.Upstream)?" "Confirm push")) {
        return
    }

    Set-Busy $true "Pushing commits..."
    try {
        $result = Invoke-Git @("push") -AllowFailure -TimeoutSeconds 120
        if ($result.TimedOut) {
            Show-Error "The push timed out. Check the network connection."
        } elseif ($result.ExitCode -ne 0) {
            Show-Error "Git push failed. Read the output for details."
        } else {
            Append-Log "`r`nPush complete.`r`n"
        }
    }
    finally {
        Set-Busy $false
        Refresh-Repository
    }
}

function Get-LocalBranches {
    $raw = (Invoke-Git @("for-each-ref", "--format=%(refname:short)", "refs/heads") -AllowFailure -Quiet).StdOut
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw -split "`r?`n" | Where-Object { $_ -ne "" })
}

function Get-BranchChoices {
    param($State)

    $local = @(Get-LocalBranches)
    # Full refnames, not short ones: git abbreviates refs/remotes/origin/HEAD to
    # plain "origin", which would otherwise be offered as a branch called origin.
    $remoteRaw = (Invoke-Git @("for-each-ref", "--format=%(refname)", "refs/remotes") -AllowFailure -Quiet).StdOut

    $choices = New-Object System.Collections.Generic.List[PSObject]

    foreach ($branch in ($local | Sort-Object)) {
        if ($branch -eq $State.Branch) {
            $choices.Add([PSCustomObject]@{
                Action = 'current'; Name = $branch; Remote = $null
                Display = "$branch   (current branch)"
            })
        } else {
            $choices.Add([PSCustomObject]@{
                Action = 'checkout'; Name = $branch; Remote = $null; Display = $branch
            })
        }
    }

    # Remote branches with no local copy yet: checking one out should create a
    # local branch that tracks it, which is what "switch to that branch" means.
    if (-not [string]::IsNullOrWhiteSpace($remoteRaw)) {
        foreach ($ref in (@($remoteRaw -split "`r?`n" | Where-Object { $_ -ne "" }) | Sort-Object)) {
            if ($ref -match '/HEAD$') { continue }
            # refs/remotes/origin/vision -> tracking name "origin/vision", branch "vision"
            $tracking = $ref -replace '^refs/remotes/', ''
            if ($tracking -notmatch '/') { continue }
            $short = $tracking -replace '^[^/]+/', ''
            if ([string]::IsNullOrWhiteSpace($short)) { continue }
            if ($local -contains $short) { continue }
            $choices.Add([PSCustomObject]@{
                Action = 'track'; Name = $short; Remote = $tracking
                Display = "$short   (on GitHub only - a local branch will be created)"
            })
        }
    }

    return $choices
}

function Select-Branch {
    param($State)

    $choices = Get-BranchChoices -State $State
    $local = @(Get-LocalBranches)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Switch branch"
    $dialog.StartPosition = "CenterParent"
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $dialog.ClientSize = New-Object System.Drawing.Size(620, 400)
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    Set-DialogIcon $dialog

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "You are on '$($State.Branch)'. Pick the branch to switch to."
    $label.Location = New-Object System.Drawing.Point(14, 12)
    $label.Size = New-Object System.Drawing.Size(590, 20)
    $dialog.Controls.Add($label)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(14, 38)
    $list.Size = New-Object System.Drawing.Size(590, 260)
    $list.Font = New-Object System.Drawing.Font("Consolas", 9)
    foreach ($choice in $choices) { [void]$list.Items.Add($choice.Display) }
    $dialog.Controls.Add($list)

    $note = New-Object System.Windows.Forms.Label
    $note.Text = ("Switching only changes the code on this computer. The robot keeps running " +
                  "whatever was deployed last until you deploy again.")
    $note.ForeColor = [System.Drawing.Color]::DimGray
    $note.Location = New-Object System.Drawing.Point(14, 304)
    $note.Size = New-Object System.Drawing.Size(590, 34)
    $dialog.Controls.Add($note)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "Switch"
    $ok.Size = New-Object System.Drawing.Size(100, 30)
    $ok.Location = New-Object System.Drawing.Point(390, 350)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Enabled = $false
    $dialog.Controls.Add($ok)

    $newBranch = New-Object System.Windows.Forms.Button
    $newBranch.Text = "New Branch..."
    $newBranch.Size = New-Object System.Drawing.Size(110, 30)
    $newBranch.Location = New-Object System.Drawing.Point(14, 350)
    $dialog.Controls.Add($newBranch)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancel"
    $cancel.Size = New-Object System.Drawing.Size(100, 30)
    $cancel.Location = New-Object System.Drawing.Point(500, 350)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)

    $createdName = $null

    # Selecting the branch you are already on is not a switch.
    $list.Add_SelectedIndexChanged({
        $ok.Enabled = ($list.SelectedIndex -ge 0) -and
                      ($choices[$list.SelectedIndex].Action -ne 'current')
    })

    $newBranch.Add_Click({
        $name = Show-InputDialog -Title "New branch" -Prompt (
            "Name for the new branch, created from '$($State.Branch)':")
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $name = $name.Trim()

        $check = Invoke-Git @("check-ref-format", "--branch", $name) -AllowFailure -Quiet
        if ($check.ExitCode -ne 0) {
            [System.Windows.Forms.MessageBox]::Show(
                $dialog,
                "'$name' is not a valid branch name. Use letters, numbers, dashes and slashes; no spaces.",
                "Invalid name",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ($local -contains $name) {
            [System.Windows.Forms.MessageBox]::Show(
                $dialog, "A branch called '$name' already exists. Pick it from the list instead.",
                "Already exists",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $script:BranchChoice = [PSCustomObject]@{ Action = 'create'; Name = $name }
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $list.Add_DoubleClick({
        if (($list.SelectedIndex -ge 0) -and ($choices[$list.SelectedIndex].Action -ne 'current')) {
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
    })

    $script:BranchChoice = $null
    $dialog.CancelButton = $cancel

    try {
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        if ($null -ne $script:BranchChoice) { return $script:BranchChoice }
        if ($list.SelectedIndex -lt 0) { return $null }
        return $choices[$list.SelectedIndex]
    }
    finally {
        $dialog.Dispose()
    }
}

function Switch-Branch {
    if ($script:IsBusy) { return }

    Refresh-Repository
    $state = $script:RepoState
    if ($null -eq $state) { return }

    if (-not $state.IsRepo) {
        Show-Error "This project is not in a Git repository, so it has no branches."
        return
    }
    if (-not $state.HasCommits) {
        Show-Error "This repository has no commits yet, so there is nothing to branch from. Commit once first."
        return
    }
    if ($state.ConflictCount -gt 0 -or $state.MergeInProgress -or $state.RebaseInProgress) {
        Show-Error "Finish or undo the merge/rebase before switching branches."
        return
    }

    # Deliberately refuses instead of stashing. An automatic stash hides the
    # student's work somewhere they will not find it, and carrying uncommitted
    # changes onto another branch is how the wrong code reaches the robot.
    if ($state.Dirty) {
        Show-Error ("Switching branches is blocked because $($state.ChangedCount) file(s) have " +
                    "uncommitted changes.`r`n`r`n" +
                    "Git would either drag those changes onto the other branch or refuse to " +
                    "switch at all.`r`n`r`n" +
                    "Use Commit All first (then Push), or undo the changes in VS Code.")
        return
    }

    $choice = Select-Branch -State $state
    if ($null -eq $choice) { return }

    $summary = switch ($choice.Action) {
        'checkout' { "Switch from '$($state.Branch)' to the existing branch '$($choice.Name)'?" }
        'track'    { "Create local branch '$($choice.Name)' tracking '$($choice.Remote)', and switch to it?" }
        'create'   { "Create a new branch '$($choice.Name)' from '$($state.Branch)', and switch to it?" }
    }
    $summary += "`r`n`r`nThe robot keeps running the last thing you deployed until you deploy again."

    if (-not (Show-WarningConfirm $summary "Switch branch")) {
        Append-Log "`r`nBranch switch cancelled.`r`n"
        Update-StateDisplay $state
        return
    }

    Set-Busy $true "Switching branch..."
    try {
        $result = switch ($choice.Action) {
            'checkout' { Invoke-Git @("checkout", $choice.Name) -AllowFailure }
            'track'    { Invoke-Git @("checkout", "-b", $choice.Name, "--track", $choice.Remote) -AllowFailure }
            'create'   { Invoke-Git @("checkout", "-b", $choice.Name) -AllowFailure }
        }

        if ($result.ExitCode -ne 0) {
            Show-Error "Could not switch branches. Read the output for details."
        } else {
            Append-Log "`r`nNow on branch '$($choice.Name)'.`r`n"
            Show-Info ("You are now on '$($choice.Name)'.`r`n`r`n" +
                       "The code in this folder changed. Build or Deploy to put it on the robot.")
        }
    }
    finally {
        Set-Busy $false
        Refresh-Repository -Fetch
    }
}

$script:DiffFiles = @()
$script:DiffPopulating = $false
$script:DiffMaxLines = 3000          # keep rendering snappy on huge diffs
$script:DiffMaxNewFileLines = 400    # per untracked file

$script:DiffColorAdd  = [System.Drawing.Color]::FromArgb(0, 110, 40)
$script:DiffColorDel  = [System.Drawing.Color]::FromArgb(170, 30, 30)
$script:DiffColorHunk = [System.Drawing.Color]::FromArgb(90, 90, 160)
$script:DiffColorHead = [System.Drawing.Color]::FromArgb(20, 20, 20)
$script:DiffColorCtx  = [System.Drawing.Color]::FromArgb(80, 80, 80)
$script:DiffColorNote = [System.Drawing.Color]::FromArgb(120, 120, 120)

function Get-ChangedFileList {
    param($State)

    $script:DiffUntrackedSkipped = 0
    $files = New-Object System.Collections.Generic.List[PSObject]

    foreach ($line in $State.StatusLines) {
        if ($line.Length -lt 4) { continue }
        $code = $line.Substring(0, 2)
        if ($code -eq '??') { continue }   # expanded to real files below
        $path = $line.Substring(3)
        # Renames are reported as "old -> new"; the new name is what to diff.
        if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }
        $path = $path.Trim().Trim('"')
        if (-not $path) { continue }
        $files.Add([PSCustomObject]@{
            Code      = $code
            Path      = $path
            Untracked = $false
        })
    }

    # git status collapses an untracked folder to a single "docs/" entry, which is
    # a directory and has no content to show. ls-files names the actual files.
    $othersRaw = (Invoke-Git @("-c", "core.quotePath=false", "ls-files", "--others",
                               "--exclude-standard") -AllowFailure -Quiet).StdOut
    if (-not [string]::IsNullOrWhiteSpace($othersRaw)) {
        $others = @($othersRaw -split "`r?`n" | Where-Object { $_ -ne "" })
        $limit = 50
        $shown = 0
        foreach ($path in $others) {
            if ($shown -ge $limit) { break }
            $clean = $path.Trim().Trim('"')
            if (-not $clean) { continue }
            $files.Add([PSCustomObject]@{ Code = '??'; Path = $clean; Untracked = $true })
            $shown++
        }
        if ($others.Count -gt $shown) { $script:DiffUntrackedSkipped = $others.Count - $shown }
    }

    return $files
}

function Add-DiffLine {
    param([string]$Text, [System.Drawing.Color]$Color, [switch]$Bold)

    $rtbDiff.SelectionStart = $rtbDiff.TextLength
    $rtbDiff.SelectionLength = 0
    $rtbDiff.SelectionColor = $Color
    if ($Bold) {
        $rtbDiff.SelectionFont = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
    } else {
        $rtbDiff.SelectionFont = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Regular)
    }
    $rtbDiff.AppendText($Text + "`r`n")
}

function Add-NewFileContent {
    param([string]$RelativePath)

    $full = Join-Path $script:ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $full)) {
        Add-DiffLine "  (file no longer exists)" $script:DiffColorNote
        return 0
    }

    $info = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
    if ($null -eq $info) { return 0 }
    if ($info.PSIsContainer) {
        Add-DiffLine "  (a whole new folder - open it to see the files inside)" $script:DiffColorNote
        return 0
    }
    if ($info.Length -gt 262144) {
        Add-DiffLine "  (new file, $([math]::Round($info.Length / 1KB)) KB - too large to show)" $script:DiffColorNote
        return 0
    }

    # Skip binaries: a NUL byte in the first block is the usual giveaway.
    try {
        $bytes = [System.IO.File]::ReadAllBytes($full)
        $probe = [Math]::Min(8192, $bytes.Length)
        for ($i = 0; $i -lt $probe; $i++) {
            if ($bytes[$i] -eq 0) {
                Add-DiffLine "  (new binary file, nothing to show)" $script:DiffColorNote
                return 0
            }
        }
        $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    catch {
        Add-DiffLine "  (could not read this file: $($_.Exception.Message))" $script:DiffColorNote
        return 0
    }

    $lines = @($content -split "`r?`n")
    $added = 0
    $shown = 0
    foreach ($line in $lines) {
        $added++
        if ($shown -ge $script:DiffMaxNewFileLines) { continue }
        Add-DiffLine ("+" + $line) $script:DiffColorAdd
        $shown++
    }
    if ($added -gt $shown) {
        Add-DiffLine "  ... $($added - $shown) more line(s) not shown" $script:DiffColorNote
    }
    return $added
}

function Render-Diff {
    if ($null -eq $rtbDiff) { return }

    $state = $script:RepoState
    $rtbDiff.Clear()

    if ($null -eq $state -or -not $state.IsRepo -or -not $state.Dirty) {
        $lblDiffTitle.Text = "Changes  -  none"
        Add-DiffLine "No changed files." $script:DiffColorNote
        return
    }

    # Index 0 of the dropdown is "all files"; anything else selects one file.
    $selected = $null
    if ($cmbDiffFile.SelectedIndex -gt 0) {
        $index = $cmbDiffFile.SelectedIndex - 1
        if ($index -lt $script:DiffFiles.Count) { $selected = $script:DiffFiles[$index] }
    }

    $tracked = @($script:DiffFiles | Where-Object { -not $_.Untracked })
    $untracked = @($script:DiffFiles | Where-Object { $_.Untracked })
    if ($null -ne $selected) {
        $tracked = @($tracked | Where-Object { $_.Path -eq $selected.Path })
        $untracked = @($untracked | Where-Object { $_.Path -eq $selected.Path })
    }

    $addedTotal = 0
    $removedTotal = 0
    $rendered = 0
    $truncated = $false

    if ($tracked.Count -gt 0) {
        # Compare against HEAD so changes already staged in VS Code still appear.
        $gitArgs = New-Object System.Collections.Generic.List[string]
        $gitArgs.Add("-c")
        $gitArgs.Add("core.quotePath=false")
        $gitArgs.Add("diff")
        $gitArgs.Add("--no-color")
        if ($state.HasCommits) { $gitArgs.Add("HEAD") }
        $gitArgs.Add("--")
        foreach ($file in $tracked) { $gitArgs.Add($file.Path) }

        $diffText = (Invoke-Git $gitArgs.ToArray() -AllowFailure -Quiet).StdOut

        if (-not [string]::IsNullOrWhiteSpace($diffText)) {
            foreach ($line in ($diffText -split "`r?`n")) {
                if ($rendered -ge $script:DiffMaxLines) { $truncated = $true; break }

                if ($line -like 'diff --git *') {
                    if ($rendered -gt 0) { Add-DiffLine "" $script:DiffColorCtx; $rendered++ }
                    $shown = $line -replace '^diff --git a/', '' -replace ' b/.*$', ''
                    Add-DiffLine $shown $script:DiffColorHead -Bold
                }
                elseif ($line -like 'index *' -or $line -like '--- *' -or $line -like '+++ *') {
                    continue          # noise: the file header above already says this
                }
                elseif ($line -like '@@*') {
                    Add-DiffLine $line $script:DiffColorHunk
                }
                elseif ($line.StartsWith('+')) {
                    Add-DiffLine $line $script:DiffColorAdd
                    $addedTotal++
                }
                elseif ($line.StartsWith('-')) {
                    Add-DiffLine $line $script:DiffColorDel
                    $removedTotal++
                }
                elseif ($line -like 'Binary files *') {
                    Add-DiffLine $line $script:DiffColorNote
                }
                else {
                    Add-DiffLine $line $script:DiffColorCtx
                }
                $rendered++
            }
        }
    }

    foreach ($file in $untracked) {
        if ($rendered -ge $script:DiffMaxLines) { $truncated = $true; break }
        if ($rendered -gt 0) { Add-DiffLine "" $script:DiffColorCtx }
        Add-DiffLine "$($file.Path)   (new file, not in Git yet)" $script:DiffColorHead -Bold
        $addedTotal += (Add-NewFileContent -RelativePath $file.Path)
        $rendered += 3
    }

    if ($truncated) {
        Add-DiffLine "" $script:DiffColorCtx
        Add-DiffLine "... output cut off. Pick a single file above to see all of it." $script:DiffColorNote
    }
    if (($null -eq $selected) -and $script:DiffUntrackedSkipped -gt 0) {
        Add-DiffLine "" $script:DiffColorCtx
        Add-DiffLine "... and $($script:DiffUntrackedSkipped) more new file(s) not listed." $script:DiffColorNote
    }

    if ($rtbDiff.TextLength -eq 0) {
        Add-DiffLine "No line changes to show for this selection." $script:DiffColorNote
    }

    $scope = if ($null -ne $selected) { $selected.Path } else { "$($script:DiffFiles.Count) file(s)" }
    $lblDiffTitle.Text = "Changes  -  $scope    +$addedTotal  -$removedTotal"

    $rtbDiff.SelectionStart = 0
    $rtbDiff.SelectionLength = 0
    $rtbDiff.ScrollToCaret()
}

function Show-DiffPanel {
    param([bool]$Visible)
    if ($null -eq $diffSplit) { return }

    if (-not $Visible) {
        $diffSplit.Panel1Collapsed = $true
        return
    }

    $diffSplit.Panel1Collapsed = $false
    try {
        # Split the right-hand area roughly in half, respecting both minimums.
        $half = [int]($diffSplit.Width / 2)
        $low = $diffSplit.Panel1MinSize
        $high = $diffSplit.Width - $diffSplit.Panel2MinSize - $diffSplit.SplitterWidth
        if ($high -gt $low) {
            $diffSplit.SplitterDistance = [Math]::Max($low, [Math]::Min($half, $high))
        }
    }
    catch {
        # A too-narrow window can reject the distance; the default is fine.
    }
}

function Show-Changes {
    if ($script:IsBusy) { return }

    $state = $script:RepoState
    if ($null -eq $state -or -not $state.IsRepo) {
        Show-Error "This project is not in a Git repository, so there are no changes to show."
        return
    }
    if (-not $state.Dirty) {
        Show-Info "There are no changed files to show."
        return
    }

    Set-Busy $true "Reading changes..."
    try {
        $script:DiffFiles = @(Get-ChangedFileList -State $state)

        $script:DiffPopulating = $true
        $cmbDiffFile.Items.Clear()
        [void]$cmbDiffFile.Items.Add("All changed files ($($script:DiffFiles.Count))")
        foreach ($file in $script:DiffFiles) {
            $tag = if ($file.Untracked) { "new" } else { $file.Code.Trim() }
            [void]$cmbDiffFile.Items.Add("[$tag] $($file.Path)")
        }
        $cmbDiffFile.SelectedIndex = 0
        $script:DiffPopulating = $false

        Show-DiffPanel $true
        Render-Diff
        Append-Log "`r`nShowing changes for $($script:DiffFiles.Count) file(s).`r`n"
    }
    catch {
        $script:DiffPopulating = $false
        Append-Log "`r`nERROR: $($_.Exception.Message)`r`n"
        Show-Error "Could not read the changes: $($_.Exception.Message)"
    }
    finally {
        Set-Busy $false
        Update-StateDisplay $script:RepoState
    }
}

function Change-Project {
    if ($script:IsBusy) { return }
    $candidates = @(Find-AllWpilibProjects)
    if ($script:ProjectRoot -and ($candidates -notcontains $script:ProjectRoot)) {
        $candidates = @($script:ProjectRoot) + $candidates
    }
    $chosen = Select-Project -Candidates $candidates -AllowBrowse
    if (-not $chosen) { return }

    Set-ActiveProject $chosen
    Append-Log "`r`n=== Switched to project: $script:ProjectRoot ===`r`n"
    if ($script:TeamNumber) {
        Append-Log "Team $($script:TeamNumber), WPILib project year $($script:ProjectYear).`r`n"
    }
    Resolve-JdkPath | Out-Null
    Update-CommandPreview
    Refresh-Repository -Fetch
}

function Open-VSCode {
    # Prefer the WPILib copy of VS Code, which has the extension installed.
    $candidates = New-Object System.Collections.Generic.List[string]
    $wpilibRoot = Join-Path $env:PUBLIC "wpilib"
    if (Test-Path -LiteralPath $wpilibRoot) {
        $years = @(Get-ChildItem -LiteralPath $wpilibRoot -Directory -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending | ForEach-Object { $_.Name })
        if ($script:ProjectYear) { $years = @($script:ProjectYear) + @($years | Where-Object { $_ -ne $script:ProjectYear }) }
        foreach ($year in $years) {
            $candidates.Add((Join-Path $wpilibRoot "$year\vscode\bin\code.cmd"))
        }
    }
    $candidates.Add((Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"))
    $candidates.Add("C:\Program Files\Microsoft VS Code\bin\code.cmd")

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            try {
                Start-Process -FilePath $candidate -ArgumentList @(".") `
                              -WorkingDirectory $script:ProjectRoot -WindowStyle Hidden
                Append-Log "`r`nOpening VS Code: $candidate`r`n"
                return
            }
            catch { }
        }
    }

    if (Test-CommandExists "code.cmd") {
        Start-Process -FilePath "code.cmd" -ArgumentList @(".") -WorkingDirectory $script:ProjectRoot -WindowStyle Hidden
        return
    }

    Show-Error "VS Code was not found. Open the WPILib VS Code shortcut manually."
}

# ---------------- UI ----------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "RCM"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1180, 860)
$form.MinimumSize = New-Object System.Drawing.Size(1000, 700)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.BackColor = $script:ColSurface

Load-BrandAssets
if ($null -ne $script:AppIcon) { $form.Icon = $script:AppIcon }

# Thin accent stripe along the very top of the window.
$accentBar = New-Object System.Windows.Forms.Panel
$accentBar.Dock = "Top"
$accentBar.Height = 4
$accentBar.BackColor = $script:ColAccent
$form.Controls.Add($accentBar)

$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = "Top"
$topPanel.Height = 116
$topPanel.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($topPanel)

# The logo already carries the RCM wordmark, so the heading beside it spells the
# name out instead of repeating the letters.
$headerLeft = 16
if ($null -ne $script:AppLogo) {
    $logoBox = New-Object System.Windows.Forms.PictureBox
    $logoBox.Image = $script:AppLogo
    $logoBox.SizeMode = "Zoom"          # keeps the square logo undistorted
    $logoBox.Size = New-Object System.Drawing.Size(52, 52)
    $logoBox.Location = New-Object System.Drawing.Point(16, 6)
    $logoBox.BackColor = [System.Drawing.Color]::Transparent
    $topPanel.Controls.Add($logoBox)
    $headerLeft = $logoBox.Right + 14
}

$title = New-Object System.Windows.Forms.Label
# Without the logo there is no wordmark on screen, so fall back to "RCM - ...".
$title.Text = if ($null -ne $script:AppLogo) {
    $script:AppLongName
} else {
    "$($script:AppName) - $($script:AppLongName)"
}
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16)
$title.ForeColor = $script:ColInk
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point($headerLeft, 14)
$topPanel.Controls.Add($title)

# Credit block, right aligned and kept there when the window is resized.
$lblCredit = New-Object System.Windows.Forms.Label
# ASCII only, deliberately. Run as a .ps1 rather than through the .exe, this file
# has no byte-order mark, so PowerShell 5.1 reads it in the system code page and
# anything fancier than ASCII turns into mojibake.
$lblCredit.Text = "$($script:AppTeam)`r`nv$($script:AppVersion)  |  built by $($script:AppAuthor)"
$lblCredit.TextAlign = "TopRight"
$lblCredit.AutoSize = $false
$lblCredit.Size = New-Object System.Drawing.Size(330, 34)
$lblCredit.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 346), 10)
$lblCredit.Anchor = "Top,Right"
$lblCredit.ForeColor = $script:ColMuted
$topPanel.Controls.Add($lblCredit)

$lblProject = New-Object System.Windows.Forms.Label
$lblProject.Text = "(no project selected)"
$lblProject.AutoEllipsis = $true
$lblProject.ForeColor = $script:ColMuted
$lblProject.Font = New-Object System.Drawing.Font("Consolas", 8.5)
# Sits under the heading, lined up with it rather than with the logo.
$lblProject.Location = New-Object System.Drawing.Point(($headerLeft + 2), ($title.Bottom + 2))
$lblProject.Size = New-Object System.Drawing.Size((760 - $headerLeft), 18)
$topPanel.Controls.Add($lblProject)

# Hairline under the status row, so the header reads as its own band.
$headerRule = New-Object System.Windows.Forms.Panel
$headerRule.Dock = "Bottom"
$headerRule.Height = 1
$headerRule.BackColor = $script:ColLine
$topPanel.Controls.Add($headerRule)

function Add-StatusPair {
    param([string]$Caption, [int]$X, [int]$Width)

    # Caption row and value row are laid out from the caption's measured height,
    # so the two never overlap whatever the font or DPI does to them.
    $cap = New-Object System.Windows.Forms.Label
    $cap.Text = $Caption.ToUpperInvariant()
    $cap.AutoSize = $true
    $cap.ForeColor = $script:ColMuted
    $cap.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
    $cap.Location = New-Object System.Drawing.Point($X, 70)
    $topPanel.Controls.Add($cap)

    $val = New-Object System.Windows.Forms.Label
    $val.Text = "..."
    # Fixed width with an ellipsis: a long branch or upstream name would
    # otherwise grow the label straight into the next column.
    $val.AutoSize = $false
    $val.AutoEllipsis = $true
    $val.Size = New-Object System.Drawing.Size($Width, 20)
    $val.ForeColor = $script:ColInk
    $val.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5)
    $val.Location = New-Object System.Drawing.Point($X, ($cap.Bottom + 2))
    $topPanel.Controls.Add($val)
    return $val
}

$lblBranchValue   = Add-StatusPair "Branch" 18  172
$lblCommitValue   = Add-StatusPair "Commit" 200 126
$lblUpstreamValue = Add-StatusPair "Remote" 336 198
$lblTeamValue     = Add-StatusPair "Team"   544  92
$lblWorkingValue  = Add-StatusPair "Files"  644 152
$lblSyncValue     = Add-StatusPair "Sync"   804 190

$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.Dock = "Top"
$buttonPanel.Height = 84
$buttonPanel.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 4)
$buttonPanel.WrapContents = $true
$buttonPanel.AutoScroll = $true
$buttonPanel.BackColor = $script:ColBar
$form.Controls.Add($buttonPanel)
$buttonPanel.BringToFront()

function New-ActionButton {
    param([string]$Text, [int]$Width = 120)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = 32
    $button.Margin = New-Object System.Windows.Forms.Padding(4, 0, 4, 4)
    $button.FlatStyle = "Flat"
    $button.BackColor = [System.Drawing.Color]::White
    $button.ForeColor = $script:ColInk
    $button.FlatAppearance.BorderColor = $script:ColLine
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(232, 238, 245)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $buttonPanel.Controls.Add($button)
    return $button
}

function Set-AccentButton {
    param([System.Windows.Forms.Button]$Button, [System.Drawing.Color]$Accent)

    $Button.Tag = $Accent
    $Button.FlatAppearance.BorderSize = 0
    $Button.BackColor = $Accent
    $Button.ForeColor = [System.Drawing.Color]::White
    $Button.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    $Button.FlatAppearance.MouseOverBackColor =
        [System.Drawing.Color]::FromArgb(
            [Math]::Min(255, $Accent.R + 26),
            [Math]::Min(255, $Accent.G + 26),
            [Math]::Min(255, $Accent.B + 26))

    # A flat button keeps its BackColor when disabled, so a greyed-out Deploy
    # would still look clickable. Repaint it on every state change instead.
    $Button.Add_EnabledChanged({
        if ($this.Enabled) {
            $this.BackColor = $this.Tag
            $this.ForeColor = [System.Drawing.Color]::White
        } else {
            $this.BackColor = $script:ColOff
            $this.ForeColor = $script:ColOffText
        }
    })
}

$btnRefresh  = New-ActionButton "Refresh / Fetch" 118
$btnBuild    = New-ActionButton "Build Robot Code" 128
$btnDeploy   = New-ActionButton "Deploy Robot Code" 136
$btnCancel   = New-ActionButton "Cancel" 76
$btnRobot    = New-ActionButton "Check Robot" 100
$btnCommit   = New-ActionButton "Commit All" 92
$btnBranch   = New-ActionButton "Switch Branch" 106
$btnPull     = New-ActionButton "Pull Safely" 92
$btnPush     = New-ActionButton "Push Commits" 106
$btnDiff     = New-ActionButton "View Changes" 106
$btnProject  = New-ActionButton "Change Project" 112
$btnVSCode   = New-ActionButton "Open VS Code" 106
$btnFolder   = New-ActionButton "Open Folder" 96
$btnStopG    = New-ActionButton "Stop Gradle" 92

Set-AccentButton $btnDeploy $script:ColGo
Set-AccentButton $btnBuild  $script:ColBuild
Set-AccentButton $btnCancel $script:ColDanger
$btnCancel.Enabled = $false

# Cancel is deliberately excluded: it must stay usable while an operation runs.
$actionButtons = @($btnRefresh, $btnBuild, $btnDeploy, $btnRobot, $btnCommit, $btnBranch, $btnPull,
                   $btnPush, $btnDiff, $btnProject, $btnVSCode, $btnFolder, $btnStopG)

$optionPanel = New-Object System.Windows.Forms.Panel
$optionPanel.Dock = "Top"
$optionPanel.Height = 30
$optionPanel.BackColor = $script:ColBar
$form.Controls.Add($optionPanel)
$optionPanel.BringToFront()

function New-OptionCheck {
    param([string]$Text, [int]$X, [int]$Width, [bool]$Checked, [string]$Tip)
    $check = New-Object System.Windows.Forms.CheckBox
    $check.Text = $Text
    $check.Checked = $Checked
    $check.AutoSize = $false
    $check.Size = New-Object System.Drawing.Size($Width, 22)
    $check.Location = New-Object System.Drawing.Point($X, 4)
    $tooltip = New-Object System.Windows.Forms.ToolTip
    $tooltip.SetToolTip($check, $Tip)
    $optionPanel.Controls.Add($check)
    return $check
}

Load-Settings

$chkOfflineDeploy = New-OptionCheck "Offline deploy" 16 110 ([bool]$script:Settings.offlineDeploy) `
    "Adds --offline to deploy so Gradle uses the local WPILib cache. This is the WPILib default and what you want at competition."
$chkOfflineBuild = New-OptionCheck "Offline build" 134 104 ([bool]$script:Settings.offlineBuild) `
    "Adds --offline to build. Leave off unless the build is failing on downloads."
$chkSkipTests = New-OptionCheck "Skip tests on deploy" 244 140 ([bool]$script:Settings.skipTests) `
    "Adds -xcheck to deploy so unit tests do not block getting on the field."

$lblCommandPreview = New-Object System.Windows.Forms.Label
$lblCommandPreview.AutoEllipsis = $true
$lblCommandPreview.ForeColor = [System.Drawing.Color]::DimGray
$lblCommandPreview.Font = New-Object System.Drawing.Font("Consolas", 8)
$lblCommandPreview.Location = New-Object System.Drawing.Point(396, 7)
$lblCommandPreview.Size = New-Object System.Drawing.Size(740, 18)
$optionPanel.Controls.Add($lblCommandPreview)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$lblOperation = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblOperation.Text = "Ready"
$lblOperation.Spring = $true      # pushes the activity bar to the far right
$lblOperation.TextAlign = "MiddleLeft"

# Activity indicator: a bar that slides side to side while work is happening.
# A real animation is used rather than a marquee progress bar because the
# marquee style is easy to mistake for a stalled progress bar.
$activityTrack = New-Object System.Windows.Forms.Panel
$activityTrack.Size = New-Object System.Drawing.Size(150, 12)
$activityTrack.BackColor = [System.Drawing.Color]::FromArgb(214, 219, 226)

$activityBar = New-Object System.Windows.Forms.Panel
$activityBar.Size = New-Object System.Drawing.Size(44, 12)
$activityBar.Location = New-Object System.Drawing.Point(0, 0)
$activityBar.BackColor = [System.Drawing.Color]::FromArgb(34, 139, 84)
$activityTrack.Controls.Add($activityBar)

$activityItem = New-Object System.Windows.Forms.ToolStripControlHost($activityTrack)
$activityItem.AutoSize = $false
$activityItem.Size = New-Object System.Drawing.Size(154, 16)
$activityItem.Margin = New-Object System.Windows.Forms.Padding(4, 3, 8, 3)
$activityItem.Available = $false

$script:ActivityDirection = 1
$activityTimer = New-Object System.Windows.Forms.Timer
$activityTimer.Interval = 25
$activityTimer.Add_Tick({
    $limit = $activityTrack.ClientSize.Width - $activityBar.Width
    if ($limit -le 0) { return }
    $next = $activityBar.Left + (7 * $script:ActivityDirection)
    if ($next -ge $limit) {
        $next = $limit
        $script:ActivityDirection = -1
    } elseif ($next -le 0) {
        $next = 0
        $script:ActivityDirection = 1
    }
    $activityBar.Left = $next
})

# Determinate progress for gradle runs, driven by counted "> Task :" lines.
$buildProgress = New-Object System.Windows.Forms.ToolStripProgressBar
$buildProgress.Style = "Continuous"
$buildProgress.Minimum = 0
$buildProgress.Maximum = 100
$buildProgress.Value = 0
$buildProgress.Size = New-Object System.Drawing.Size(170, 16)
$buildProgress.Available = $false

[void]$statusStrip.Items.Add($lblOperation)
[void]$statusStrip.Items.Add($buildProgress)
[void]$statusStrip.Items.Add($activityItem)
$form.Controls.Add($statusStrip)

function Show-BuildProgress {
    param([bool]$Visible, [int]$Percent = 0)
    if ($null -eq $buildProgress) { return }
    $buildProgress.Value = [Math]::Min(100, [Math]::Max(0, $Percent))
    $buildProgress.Available = $Visible
}

function Update-BuildProgress {
    param([int]$TasksSeen, [int]$Expected, [string]$Label)
    if ($null -eq $buildProgress) { return }

    if ($Expected -le 0) { $Expected = 1 }
    $percent = [int](($TasksSeen / [double]$Expected) * 100)

    # Never let the bar reach the end before the run actually finishes: the
    # estimate is a guess and overshooting past it is normal.
    if ($percent -gt 97) { $percent = 97 }
    $buildProgress.Value = [Math]::Max(1, $percent)

    if ($Label) {
        if ($TasksSeen -gt $Expected) {
            $lblOperation.Text = "$Label  (task $TasksSeen, longer than usual)"
        } else {
            $lblOperation.Text = "$Label  (task $TasksSeen of about $Expected)"
        }
    }
}

function Set-ActivityIndicator {
    param([bool]$Active)
    if ($null -eq $activityItem) { return }

    if ($Active) {
        if (-not $activityItem.Available) {
            $activityBar.Left = 0
            $script:ActivityDirection = 1
            $activityItem.Available = $true
        }
        $activityTimer.Start()
    } else {
        $activityTimer.Stop()
        $activityItem.Available = $false
    }
}

$mainSplit = New-Object System.Windows.Forms.SplitContainer
$mainSplit.Dock = "Fill"
$mainSplit.Orientation = "Horizontal"
$form.Controls.Add($mainSplit)
$mainSplit.BringToFront()

# Docked controls are laid out from the back of the z-order forward, so the
# back-most one claims the outermost edge. The stripe is added early but has to
# end up above the header, which means sending it to the back once everything
# else is in place.
$accentBar.SendToBack()

$upperSplit = New-Object System.Windows.Forms.SplitContainer
$upperSplit.Dock = "Fill"
$mainSplit.Panel1.Controls.Add($upperSplit)

$leftTabs = New-Object System.Windows.Forms.TabControl
$leftTabs.Dock = "Fill"
$upperSplit.Panel1.Controls.Add($leftTabs)

$tabWarnings = New-Object System.Windows.Forms.TabPage
$tabWarnings.Text = "Warnings"
$leftTabs.TabPages.Add($tabWarnings)

$txtWarnings = New-Object System.Windows.Forms.TextBox
$txtWarnings.Dock = "Fill"
$txtWarnings.Multiline = $true
$txtWarnings.ReadOnly = $true
$txtWarnings.ScrollBars = "Vertical"
$txtWarnings.BackColor = [System.Drawing.Color]::White
$txtWarnings.BorderStyle = "None"
$txtWarnings.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$tabWarnings.Controls.Add($txtWarnings)

$tabFiles = New-Object System.Windows.Forms.TabPage
$tabFiles.Text = "Changed Files"
$leftTabs.TabPages.Add($tabFiles)

$txtFiles = New-Object System.Windows.Forms.TextBox
$txtFiles.Dock = "Fill"
$txtFiles.Multiline = $true
$txtFiles.ReadOnly = $true
$txtFiles.ScrollBars = "Both"
$txtFiles.WordWrap = $false
$txtFiles.Font = New-Object System.Drawing.Font("Consolas", 9)
$tabFiles.Controls.Add($txtFiles)

$tabCommands = New-Object System.Windows.Forms.TabPage
$tabCommands.Text = "Commands"
$leftTabs.TabPages.Add($tabCommands)

$txtCommands = New-Object System.Windows.Forms.TextBox
$txtCommands.Dock = "Fill"
$txtCommands.Multiline = $true
$txtCommands.ReadOnly = $true
$txtCommands.ScrollBars = "Both"
$txtCommands.WordWrap = $false
$txtCommands.BackColor = [System.Drawing.Color]::White
$txtCommands.BorderStyle = "None"
$txtCommands.Font = New-Object System.Drawing.Font("Consolas", 9)
$tabCommands.Controls.Add($txtCommands)

# The diff view lives in its own column between the left tabs and the commit
# lists. It starts collapsed and only takes space once View Changes is used.
$diffSplit = New-Object System.Windows.Forms.SplitContainer
$diffSplit.Dock = "Fill"
$diffSplit.Orientation = "Vertical"
# Panel1MinSize/Panel2MinSize are deliberately left at their defaults. Setting
# them here throws: before layout the container is only 150 px wide, which is
# narrower than any useful pair of minimums. Show-DiffPanel clamps instead.
$upperSplit.Panel2.Controls.Add($diffSplit)

$diffPanel = New-Object System.Windows.Forms.Panel
$diffPanel.Dock = "Fill"
$diffPanel.BackColor = [System.Drawing.Color]::White
$diffSplit.Panel1.Controls.Add($diffPanel)

$diffTitleBar = New-Object System.Windows.Forms.Panel
$diffTitleBar.Dock = "Top"
$diffTitleBar.Height = 26
$diffTitleBar.BackColor = [System.Drawing.Color]::FromArgb(235, 239, 244)
$diffPanel.Controls.Add($diffTitleBar)

# Added before the title label so the Fill label takes only the space left over.
$btnDiffClose = New-Object System.Windows.Forms.Button
$btnDiffClose.Text = "X"
$btnDiffClose.Dock = "Right"
$btnDiffClose.Width = 28
$btnDiffClose.FlatStyle = "Flat"
$btnDiffClose.FlatAppearance.BorderSize = 0
$btnDiffClose.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnDiffClose.ForeColor = [System.Drawing.Color]::FromArgb(120, 40, 40)
$btnDiffClose.BackColor = [System.Drawing.Color]::FromArgb(235, 239, 244)
$diffTitleBar.Controls.Add($btnDiffClose)
$diffCloseTip = New-Object System.Windows.Forms.ToolTip
$diffCloseTip.SetToolTip($btnDiffClose, "Close the changes view")

$lblDiffTitle = New-Object System.Windows.Forms.Label
$lblDiffTitle.Text = "Changes"
$lblDiffTitle.Dock = "Fill"
$lblDiffTitle.TextAlign = "MiddleLeft"
$lblDiffTitle.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
$lblDiffTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
$diffTitleBar.Controls.Add($lblDiffTitle)

$diffFileBar = New-Object System.Windows.Forms.Panel
$diffFileBar.Dock = "Top"
$diffFileBar.Height = 30
$diffFileBar.Padding = New-Object System.Windows.Forms.Padding(5, 4, 5, 3)
$diffFileBar.BackColor = [System.Drawing.Color]::White
$diffPanel.Controls.Add($diffFileBar)

$cmbDiffFile = New-Object System.Windows.Forms.ComboBox
$cmbDiffFile.Dock = "Fill"
$cmbDiffFile.DropDownStyle = "DropDownList"
$cmbDiffFile.Font = New-Object System.Drawing.Font("Consolas", 9)
$diffFileBar.Controls.Add($cmbDiffFile)

$rtbDiff = New-Object System.Windows.Forms.RichTextBox
$rtbDiff.Dock = "Fill"
$rtbDiff.ReadOnly = $true
$rtbDiff.WordWrap = $false
$rtbDiff.DetectUrls = $false
$rtbDiff.BackColor = [System.Drawing.Color]::White
$rtbDiff.BorderStyle = "None"
$rtbDiff.Font = New-Object System.Drawing.Font("Consolas", 9)
$diffPanel.Controls.Add($rtbDiff)

$commitTabs = New-Object System.Windows.Forms.TabControl
$commitTabs.Dock = "Fill"
$diffSplit.Panel2.Controls.Add($commitTabs)

function New-CommitList {
    $list = New-Object System.Windows.Forms.ListView
    $list.Dock = "Fill"
    $list.View = "Details"
    $list.FullRowSelect = $true
    $list.GridLines = $true
    [void]$list.Columns.Add("Commit", 75)
    [void]$list.Columns.Add("Date", 85)
    [void]$list.Columns.Add("Author", 115)
    [void]$list.Columns.Add("Message", 360)
    return $list
}

$tabRecent = New-Object System.Windows.Forms.TabPage
$tabRecent.Text = "Recent Local Commits"
$commitTabs.TabPages.Add($tabRecent)
$listRecent = New-CommitList
$tabRecent.Controls.Add($listRecent)

$tabIncoming = New-Object System.Windows.Forms.TabPage
$tabIncoming.Text = "Incoming from GitHub"
$commitTabs.TabPages.Add($tabIncoming)
$listIncoming = New-CommitList
$tabIncoming.Controls.Add($listIncoming)

$tabOutgoing = New-Object System.Windows.Forms.TabPage
$tabOutgoing.Text = "Not Pushed"
$commitTabs.TabPages.Add($tabOutgoing)
$listOutgoing = New-CommitList
$tabOutgoing.Controls.Add($listOutgoing)

# Collapsed last: SplitContainer needs its panels populated before it will
# accept a collapse without complaining about minimum sizes.
$diffSplit.Panel1Collapsed = $true

$outputGroup = New-Object System.Windows.Forms.GroupBox
$outputGroup.Text = "Command Output"
$outputGroup.Dock = "Fill"
$outputGroup.Padding = New-Object System.Windows.Forms.Padding(8)
$mainSplit.Panel2.Controls.Add($outputGroup)

$txtOutput = New-Object System.Windows.Forms.RichTextBox
$txtOutput.Dock = "Fill"
$txtOutput.ReadOnly = $true
$txtOutput.BackColor = [System.Drawing.Color]::FromArgb(25, 28, 34)
$txtOutput.ForeColor = [System.Drawing.Color]::Gainsboro
$txtOutput.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtOutput.WordWrap = $false
$txtOutput.DetectUrls = $false
$outputGroup.Controls.Add($txtOutput)

# ---------------- Events ----------------

function Update-CommandPreview {
    if (-not $script:UiReady) { return }

    $team = if ($script:TeamNumber) { [string]$script:TeamNumber } else { "NOT FOUND" }

    try {
        $lblCommandPreview.Text = "team $team  |  deploy: cmd.exe " + (Get-GradleCommandLine -Task "deploy")
    }
    catch {
        $lblCommandPreview.Text = ""
    }

    if ($null -eq $txtCommands) { return }

    try {
        $jdk = if ($script:JdkPath) { $script:JdkPath } else { "(none found - Gradle will use java from PATH)" }
        $jdkVersion = if ($script:JdkMajor) { "Java $($script:JdkMajor)" } else { "version unknown" }

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("These are the exact commands the Build and Deploy buttons run.")
        $lines.Add("They match what the WPILib extension runs in VS Code.")
        $lines.Add("")
        $lines.Add("Team number  : $team")
        $lines.Add("               (read from .wpilib\wpilib_preferences.json)")
        $lines.Add("Project year : $(if ($script:ProjectYear) { $script:ProjectYear } else { 'unknown' })")
        $lines.Add("JDK          : $jdk")
        $lines.Add("               $jdkVersion, also passed as JAVA_HOME")
        $lines.Add("Project      : $script:ProjectRoot")
        $lines.Add("")
        $lines.Add("BUILD")
        $lines.Add("  cmd.exe " + (Get-GradleCommandLine -Task "build"))
        $lines.Add("")
        $lines.Add("  Build takes no -PteamNumber, and neither does VS Code's Build")
        $lines.Add("  Robot Code. Nothing is sent to the robot, so no team number is")
        $lines.Add("  needed. GradleRIO reads it from wpilib_preferences.json if a")
        $lines.Add("  task ever asks for it. Team $team is shown above so you can")
        $lines.Add("  still check it before deploying.")
        $lines.Add("")
        $lines.Add("DEPLOY")
        $lines.Add("  cmd.exe " + (Get-GradleCommandLine -Task "deploy"))
        $lines.Add("")
        if ($script:TeamNumber) {
            $high = [math]::Floor([int]$script:TeamNumber / 100)
            $low = [int]$script:TeamNumber % 100
            $lines.Add("  Deploy passes -PteamNumber=$team, which is how GradleRIO works")
            $lines.Add("  out where the robot is:")
            # The extra parentheses matter: inside Add(...) a bare comma would be
            # read as a second method argument instead of a -f operand.
            $lines.Add(("    {0,-26}({1})" -f "roborio-$team-FRC.local", "radio or USB, by name"))
            $lines.Add(("    {0,-26}({1})" -f "10.$high.$low.2", "static team IP"))
            $lines.Add(("    {0,-26}({1})" -f "172.22.11.2", "USB"))
            $lines.Add("")
            $lines.Add("  If that team number is wrong, fix it in VS Code with")
            $lines.Add("  'WPILib: Set Team Number', or edit wpilib_preferences.json.")
        } else {
            $lines.Add("  WARNING: no team number was found, so -PteamNumber is not being")
            $lines.Add("  passed. Set it in VS Code with 'WPILib: Set Team Number'.")
        }

        $txtCommands.Text = ($lines -join "`r`n")
    }
    catch {
        $txtCommands.Text = "Could not build the command preview: $($_.Exception.Message)"
    }
}

function Save-OptionSettings {
    $script:Settings.offlineDeploy = $chkOfflineDeploy.Checked
    $script:Settings.offlineBuild = $chkOfflineBuild.Checked
    $script:Settings.skipTests = $chkSkipTests.Checked
    Save-Settings
    Update-CommandPreview
}

$chkOfflineDeploy.Add_CheckedChanged({ Save-OptionSettings })
$chkOfflineBuild.Add_CheckedChanged({ Save-OptionSettings })
$chkSkipTests.Add_CheckedChanged({ Save-OptionSettings })

$btnRefresh.Add_Click({ Refresh-Repository -Fetch })
$btnBuild.Add_Click({ Run-GradleTask -Task "build" })
$btnDeploy.Add_Click({ Run-GradleTask -Task "deploy" -Deploy })
$btnPull.Add_Click({ Safe-Pull })
$btnPush.Add_Click({ Push-Commits })
$btnCommit.Add_Click({ Commit-All })
$btnBranch.Add_Click({ Switch-Branch })
$btnRobot.Add_Click({ Check-RobotConnection })
$btnProject.Add_Click({ Change-Project })
$btnVSCode.Add_Click({ Open-VSCode })
$btnStopG.Add_Click({ Stop-GradleDaemons })

$btnCancel.Add_Click({
    if ($null -eq $script:CurrentProcess) { return }
    if (Show-WarningConfirm ("Stop the running command?`r`n`r`nStopping a deploy partway through can " +
                             "leave old code on the robot.") "Cancel operation") {
        $script:CancelRequested = $true
        $lblOperation.Text = "Cancelling..."
    }
})

$btnDiff.Add_Click({ Show-Changes })
$btnDiffClose.Add_Click({ Show-DiffPanel $false })
$cmbDiffFile.Add_SelectedIndexChanged({
    # Ignore the events fired while the dropdown is being filled.
    if (-not $script:DiffPopulating) { Render-Diff }
})

$btnFolder.Add_Click({
    Start-Process -FilePath "explorer.exe" -ArgumentList @($script:ProjectRoot)
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:IsBusy) {
        if (Show-WarningConfirm ("A command is still running. Closing now will stop it, which can " +
                                 "leave the robot with old code.`r`n`r`nClose anyway?") "Still running") {
            $script:CancelRequested = $true
            if ($null -ne $script:CurrentProcess) { Stop-ProcessTree $script:CurrentProcess }
        } else {
            $e.Cancel = $true
        }
    }
})

$form.Add_FormClosed({
    if ($null -ne $activityTimer) {
        $activityTimer.Stop()
        $activityTimer.Dispose()
    }
})

$form.Add_Shown({
    # SplitContainer dimensions are only valid once WinForms has laid out.
    try {
        $mainSplit.SplitterDistance = [Math]::Max(250, [Math]::Min(400, $mainSplit.Height - 200))
        $upperSplit.SplitterDistance = [Math]::Max(300, [Math]::Min(430, $upperSplit.Width - 380))
    }
    catch {
        Append-Log "Layout warning: $($_.Exception.Message)`r`n"
    }

    $script:UiReady = $true
    Append-Log "$($script:AppName) - $($script:AppLongName)  v$($script:AppVersion)`r`n"
    Append-Log "Built by $($script:AppAuthor)  |  $($script:AppTeam)`r`n"
    Append-Log "--------------------------------------------------------------`r`n"

    if (-not (Test-CommandExists "git.exe")) {
        Append-Log "WARNING: git was not found on PATH. Git features will be unavailable.`r`n"
    }

    $project = Resolve-StartupProject
    if (-not $project) {
        Show-Error ("No robot project was selected, so there is nothing to manage.`r`n`r`n" +
                    "Put this script in a WPILib project folder, or use Change Project after " +
                    "closing this message.")
        Append-Log "No project selected. Use Change Project to pick one.`r`n"
        foreach ($control in $actionButtons) { $control.Enabled = $false }
        $btnProject.Enabled = $true
        $btnFolder.Enabled = $false
        return
    }

    Set-ActiveProject $project
    Append-Log "Project: $script:ProjectRoot`r`n"
    if ($script:TeamNumber) {
        Append-Log "Team $($script:TeamNumber), WPILib project year $($script:ProjectYear).`r`n"
    }
    Resolve-JdkPath | Out-Null
    Update-CommandPreview
    Refresh-Repository -Fetch
})

[void]$form.ShowDialog()
$form.Dispose()
