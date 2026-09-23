using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Threading;

// Test-only minimum call duration, including native work rather than adding a
// delay before it. The original total Runtime deadline remains in force.
public static class Tk07CleanupDelay
{
    private static void Observe(string path, string stage, int pid)
    {
        File.AppendAllText(path, DateTime.UtcNow.ToString("o") + " " + stage + " pid=" + pid.ToString(CultureInfo.InvariantCulture) + Environment.NewLine);
    }

    public static int Main(string[] args)
    {
        int pid = int.Parse(args[0], CultureInfo.InvariantCulture);
        long ticks = long.Parse(args[1], CultureInfo.InvariantCulture);
        long completeNotBefore = DateTime.UtcNow.AddMilliseconds(int.Parse(args[2], CultureInfo.InvariantCulture)).Ticks;
        string observationPath = args[3];
        Observe(observationPath, "proxy-start", Process.GetCurrentProcess().Id);
        using (Process root = Process.GetProcessById(pid))
        {
            if (root.StartTime.ToUniversalTime().Ticks != ticks) return 2;
            if (root.HasExited) return 3;
            var info = new ProcessStartInfo {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "taskkill.exe"),
                Arguments = "/PID " + pid.ToString(CultureInfo.InvariantCulture) + " /T /F",
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using (Process cleanup = Process.Start(info))
            {
                Observe(observationPath, "native-start", cleanup.Id);
                cleanup.WaitForExit();
                Observe(observationPath, "native-exit-" + cleanup.ExitCode.ToString(CultureInfo.InvariantCulture), cleanup.Id);
                int remaining = (int)Math.Max(0, (completeNotBefore - DateTime.UtcNow.Ticks) / TimeSpan.TicksPerMillisecond);
                Thread.Sleep(remaining);
                Observe(observationPath, "completion-window-reached", pid);
                return cleanup.ExitCode;
            }
        }
    }
}
