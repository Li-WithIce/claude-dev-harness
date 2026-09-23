using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Threading;

// Test-only latency injection. Avoid an extra PowerShell startup in the measured
// cleanup interval; the original total Runtime deadline remains in force.
public static class Tk07CleanupDelay
{
    public static int Main(string[] args)
    {
        int pid = int.Parse(args[0], CultureInfo.InvariantCulture);
        long ticks = long.Parse(args[1], CultureInfo.InvariantCulture);
        long launchNotBefore = long.Parse(args[2], CultureInfo.InvariantCulture);
        using (Process root = Process.GetProcessById(pid))
        {
            if (root.StartTime.ToUniversalTime().Ticks != ticks) return 2;
            // The injected startup window includes CLR/proxy startup itself.
            // Do not accidentally add that startup cost on top of the window.
            int remaining = (int)Math.Max(0, (launchNotBefore - DateTime.UtcNow.Ticks) / TimeSpan.TicksPerMillisecond);
            Thread.Sleep(remaining);
            if (root.HasExited) return 3;
            var info = new ProcessStartInfo {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "taskkill.exe"),
                Arguments = "/PID " + pid.ToString(CultureInfo.InvariantCulture) + " /T /F",
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using (Process cleanup = Process.Start(info))
            {
                cleanup.WaitForExit();
                return cleanup.ExitCode;
            }
        }
    }
}
