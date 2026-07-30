// Wrapper that turns RCM.ps1 into a double-clickable .exe.
//
// The script is embedded as a resource, written to a temp folder at startup, and
// run with powershell.exe. RCM_SCRIPT_DIR tells the script where the .exe
// actually lives, since its own folder is what it scans for robot projects.
//
// Built by Build-Exe.ps1. Do not edit the copy inside a project folder.

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

internal static class Launcher
{
    private const string ResourceName = "RCM.ps1";

    [STAThread]
    private static int Main(string[] arguments)
    {
        try
        {
            string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            string scriptPath = ExtractScript();
            string iconPath = ExtractAsset("RCM.ico");
            string logoPath = ExtractAsset("RCM.png");

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            // -STA is required for Windows Forms; -NoProfile keeps a user profile
            // from interfering; -ExecutionPolicy Bypass avoids an unsigned-script
            // block on locked-down machines.
            psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \""
                            + scriptPath + "\"" + FormatArguments(arguments);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = exeDir;
            psi.EnvironmentVariables["RCM_SCRIPT_DIR"] = exeDir;
            if (iconPath != null)
            {
                psi.EnvironmentVariables["RCM_ICON"] = iconPath;
            }
            if (logoPath != null)
            {
                psi.EnvironmentVariables["RCM_LOGO"] = logoPath;
            }

            using (Process child = Process.Start(psi))
            {
                child.WaitForExit();
                return child.ExitCode;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Could not start RCM.\r\n\r\n" + ex.Message,
                "RCM",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }

    // Passes through anything given to the .exe, so a shortcut or a dropped
    // folder can name the project to open:
    //   RCM.exe "C:\path\to\robot project"
    private static string FormatArguments(string[] arguments)
    {
        if (arguments == null || arguments.Length == 0)
        {
            return string.Empty;
        }

        StringBuilder builder = new StringBuilder();
        foreach (string argument in arguments)
        {
            if (string.IsNullOrEmpty(argument))
            {
                continue;
            }
            // A trailing backslash would escape the closing quote, so double it.
            string value = argument.Replace("\"", "\\\"");
            if (value.EndsWith("\\"))
            {
                value += "\\";
            }
            builder.Append(" \"").Append(value).Append("\"");
        }
        return builder.ToString();
    }

    // Writes an embedded binary asset (the icon, the logo) next to the extracted
    // script and returns its path, or null if it was not embedded. Missing
    // artwork is never fatal: the window just falls back to plain text.
    private static string ExtractAsset(string name)
    {
        try
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            {
                if (stream == null)
                {
                    return null;
                }

                string path = Path.Combine(TempDirectory(), name);
                using (FileStream file = new FileStream(path, FileMode.Create, FileAccess.Write))
                {
                    stream.CopyTo(file);
                }
                return path;
            }
        }
        catch
        {
            return null;
        }
    }

    private static string TempDirectory()
    {
        string dir = Path.Combine(Path.GetTempPath(), "RCM");
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static string ExtractScript()
    {
        string script;
        using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName))
        {
            if (stream == null)
            {
                throw new InvalidOperationException(
                    "The embedded script is missing. Rebuild the .exe with Build-Exe.ps1.");
            }
            using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true))
            {
                script = reader.ReadToEnd();
            }
        }

        string path = Path.Combine(TempDirectory(), ResourceName);

        // A byte-order mark makes Windows PowerShell 5.1 read the file as UTF-8
        // regardless of the system code page.
        File.WriteAllText(path, script, new UTF8Encoding(true));
        return path;
    }
}
