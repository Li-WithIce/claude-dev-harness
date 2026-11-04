// Windows Script Host avoids an extra CLR startup inside the native cleanup
// window. The caller holds the root handle and validates its receipt identity.
// Keep real taskkill, both output streams, and the 1200ms minimum completion.
var args = WScript.Arguments;
var pid = args(0);
if (!/^\d+$/.test(pid)) WScript.Quit(2);
var completeNotBefore = new Date().getTime() + parseInt(args(1), 10);
var files = new ActiveXObject("Scripting.FileSystemObject");
function observe(stage, processId) {
    var log = files.OpenTextFile(args(2), 8, true);
    try {
        log.WriteLine(new Date().getTime() + " " + stage + " pid=" + processId);
    } finally { log.Close(); }
}
observe("proxy-start", pid);
var shell = new ActiveXObject("WScript.Shell");
var utility = shell.Exec('"' + args(3) + '" /PID ' + pid + ' /T /F');
observe("native-start", utility.ProcessID);
// This fixed two-process fixture has bounded native output; preserve both
// streams instead of treating taskkill exit zero as sufficient evidence.
WScript.StdOut.Write(utility.StdOut.ReadAll());
WScript.StdErr.Write(utility.StdErr.ReadAll());
while (utility.Status === 0) WScript.Sleep(1);
var exitCode = utility.ExitCode;
observe("native-exit-" + exitCode, utility.ProcessID);
var remaining = Math.max(0, completeNotBefore - new Date().getTime());
WScript.Sleep(remaining);
observe("completion-window-reached", pid);
WScript.Quit(exitCode);
