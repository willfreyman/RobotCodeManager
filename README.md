# RCM - Robot Code Manager

**Built by 416aab - Will Freyman** for Nightbots FRC 10686.

A one-window launcher for WPILib robot projects: check Git state, build, and
deploy, with guardrails so nobody deploys something they did not mean to.

## Running it

Double-click `RCM.exe`. **It does not have to live near the
robot projects** - put it on the Desktop, in a tools folder, on a USB stick, or
pin it to the taskbar.

It works out which project to open in this order:

1. A project folder passed on the command line, so a shortcut can pin one project:
   `RCM.exe "C:\path\to\robot project"`
2. Its own folder, if that folder is a robot project. This is why the copy inside
   `SWERVE_BEST` always manages SWERVE_BEST.
3. The project opened last.
4. Otherwise it asks, listing every project it knows about.

The first time on a new machine, use **Browse** to pick a project, or **Search a
Folder** to point at the folder your projects live in. After that it remembers
both the projects and the folder holding them, so it finds everything from
anywhere - no configuration file to edit.

Remembered state lives in `%LOCALAPPDATA%\RCM\settings.json`.
Delete that file to start over.

You can also run the script directly, without building anything:

```
powershell -ExecutionPolicy Bypass -File .\RCM.ps1
```

## Files

| File | What it is |
| --- | --- |
| `RCM.ps1` | The whole application. This is the only file to edit. |
| `ExeLauncher.cs` | Tiny C# wrapper that embeds the script and launches it windowless. |
| `Build-Exe.ps1` | Builds the .exe and copies it to the project folders. |
| `RCM.ico` | Window, taskbar and Explorer icon. Embedded into the .exe. |
| `RCM.png` | Logo shown in the window header. Embedded into the .exe. |
| `RCM.exe` | The build output. Rebuild after every script edit. |

## Rebuilding

The script is **embedded inside the .exe**, so editing the `.ps1` changes
nothing until you rebuild:

```
powershell -ExecutionPolicy Bypass -File .\Build-Exe.ps1
```

That builds here and also copies the .exe into the project named by
`$CopyToDefault` at the top of `Build-Exe.ps1` (`SWERVE_BEST` by default - change
it to your own). To send it elsewhere for one build:

```
powershell -ExecutionPolicy Bypass -File .\Build-Exe.ps1 -CopyTo 'BigBird_SR-71','SWERVE_BEST'
```

Add `-StopRunning` when a copy is open, which is the usual reason a build fails.
It refuses to close an instance that is mid-build or mid-deploy unless you also
pass `-Force`.

The build parse-checks the script first and will not produce an .exe from a file
with syntax errors.

`RCM.ico` and `RCM.png` are compiled into the .exe, so it stays a single portable
file with no artwork to copy alongside it. Replace either file and rebuild to
change the branding; if one is missing the build says so and falls back to the
default icon and a plain text heading.

## Build and deploy commands

The Build and Deploy buttons run what the WPILib VS Code extension runs, so the
two agree:

```
build   cmd.exe /d /c gradlew.bat build [--offline] -Dorg.gradle.java.home="<jdk>"
deploy  cmd.exe /d /c gradlew.bat deploy -PteamNumber=<n> [-xcheck] [--offline] -Dorg.gradle.java.home="<jdk>"
```

`JAVA_HOME` is set to the same JDK. The team number and project year come from
the project's `.wpilib/wpilib_preferences.json`; the JDK is the WPILib one for
that year. The **Commands** tab shows the exact command lines before you run
anything.

Offline deploy is on by default, matching WPILib's own default, which is what you
want at a competition with no internet.

## Staying up to date

RCM checks GitHub for a newer release when it starts. The check runs in the
background and is silent unless there is something newer, so a laptop with no
internet - a robot network, or a venue with nothing but the field - is never held
up by it.

When a newer version exists, the **Check Updates** button turns green and reads
*Update to vX.Y.Z*. Click it for the release notes and a link to the download.
Updating means replacing `RCM.exe`; settings, remembered projects and calibrated
build times all live outside the .exe and are kept.

Click **Check Updates** any time to check on demand; unlike the startup check it
reports the result either way. To turn the startup check off, set
`"checkUpdatesOnStart": false` in `%LOCALAPPDATA%\RCM\settings.json`.

## Guardrails

- Deploy confirms first, listing branch, commit, uncommitted-file count, whether
  the robot answered a ping, and the exact command.
- Build and deploy are blocked while Git has a conflict or an unfinished
  merge/rebase.
- Pull is fast-forward only, and blocked when the branch has diverged or the tree
  is dirty. Push is blocked when the remote is ahead.
- Switching branches is blocked while there are uncommitted changes. It never
  stashes, because a stash is somewhere a student will not find it again.
- Every deploy appends a record to `<project>/.deploy-history/deployments.jsonl`
  with the commit, dirty state, and exit code, plus a full log per run. That
  folder ignores itself in Git.

## Notes

- Windows PowerShell 5.1 and PowerShell 7 both work. No modules to install; the
  .exe is compiled with the C# compiler included in the .NET Framework.
- `*.exe` is ignored by the robot projects' `.gitignore`, so copies dropped into
  a project are never committed. That also means git will not distribute it:
  copy it to teammates by hand.

## Credits

**RCM - Robot Code Manager** was built by **416aab - Will Freyman** for
Nightbots FRC 10686.

Build and deploy behaviour is matched to the WPILib VS Code extension
(`wpilibsuite/vscode-wpilib`) so the two agree on what reaches the robot.
