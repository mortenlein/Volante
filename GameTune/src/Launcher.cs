// GameTune launcher - compiled into GameTune.exe by tools\Build-Exe.ps1 (csc.exe).
// A thin native front door: it finds the GameTune folder next to the exe and opens
// the WPF GUI by running the plain-text .ps1 on disk with a hidden console.
// The exe carries an admin manifest (auto-UAC) and is a Windows (no-console) app.
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class GameTuneLauncher
{
    [STAThread]
    static void Main()
    {
        try
        {
            string exeDir = AppDomain.CurrentDomain.BaseDirectory;
            string gui    = Path.Combine(exeDir, @"src\GUI\Show-OptimizerGui.ps1");
            string engine = Path.Combine(exeDir, @"src\Engine\Optimizer.Engine.psm1");

            if (!File.Exists(gui) || !File.Exists(engine))
            {
                MessageBox.Show(
                    "GameTune's program files weren't found next to the app.\n" +
                    "Keep GameTune.exe in the GameTune folder (with the 'src' folder).\n\n" +
                    "Looked in: " + exeDir,
                    "GameTune", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            var psi = new ProcessStartInfo
            {
                FileName        = "powershell.exe",
                Arguments       = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden " +
                                  "-File \"" + gui + "\" -EnginePath \"" + engine + "\"",
                UseShellExecute = false,
                CreateNoWindow  = true
            };

            var p = Process.Start(psi);
            p.WaitForExit();
        }
        catch (Exception ex)
        {
            MessageBox.Show("GameTune failed to start:\n" + ex.Message,
                "GameTune", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
