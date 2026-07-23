using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace DevHarness.Validation
{
    public sealed class JobController : IDisposable
    {
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const int JobObjectBasicAccountingInformation = 1;
        private const int JobObjectExtendedLimitInformation = 9;
        private const uint WaitObject0 = 0;
        private const uint WaitFailed = 0xFFFFFFFF;

        private IntPtr _handle;

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicAccountingInformation
        {
            public long TotalUserTime;
            public long TotalKernelTime;
            public long ThisPeriodTotalUserTime;
            public long ThisPeriodTotalKernelTime;
            public uint TotalPageFaultCount;
            public uint TotalProcesses;
            public uint ActiveProcesses;
            public uint TotalTerminatedProcesses;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimitInformation
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimitInformation
        {
            public BasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength,
            out uint returnedLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public JobController()
        {
            _handle = CreateJobObject(IntPtr.Zero, null);
            if (_handle == IntPtr.Zero)
            {
                throw NewWin32Exception("CreateJobObject");
            }

            try
            {
                var information = new ExtendedLimitInformation();
                information.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
                int size = Marshal.SizeOf<ExtendedLimitInformation>();
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    Marshal.StructureToPtr(information, buffer, false);
                    if (!SetInformationJobObject(
                        _handle,
                        JobObjectExtendedLimitInformation,
                        buffer,
                        (uint)size))
                    {
                        throw NewWin32Exception("SetInformationJobObject");
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            catch
            {
                Close();
                throw;
            }
        }

        public void Assign(Process process)
        {
            if (process == null)
            {
                throw new ArgumentNullException(nameof(process));
            }

            EnsureOpen();
            if (!AssignProcessToJobObject(_handle, process.Handle))
            {
                throw NewWin32Exception("AssignProcessToJobObject");
            }
        }

        public uint ActiveProcessCount
        {
            get
            {
                EnsureOpen();
                int size = Marshal.SizeOf<BasicAccountingInformation>();
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    uint returnedLength;
                    if (!QueryInformationJobObject(
                        _handle,
                        JobObjectBasicAccountingInformation,
                        buffer,
                        (uint)size,
                        out returnedLength))
                    {
                        throw NewWin32Exception("QueryInformationJobObject");
                    }

                    return Marshal.PtrToStructure<BasicAccountingInformation>(buffer).ActiveProcesses;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
        }

        public bool TerminateAndWait(uint exitCode, int timeoutMilliseconds)
        {
            if (timeoutMilliseconds < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(timeoutMilliseconds));
            }

            EnsureOpen();
            if (ActiveProcessCount == 0)
            {
                return true;
            }

            if (!TerminateJobObject(_handle, exitCode))
            {
                throw NewWin32Exception("TerminateJobObject");
            }

            uint waitResult = WaitForSingleObject(_handle, (uint)timeoutMilliseconds);
            if (waitResult == WaitFailed)
            {
                throw NewWin32Exception("WaitForSingleObject");
            }

            return waitResult == WaitObject0 && ActiveProcessCount == 0;
        }

        public void Close()
        {
            IntPtr handle = _handle;
            if (handle == IntPtr.Zero)
            {
                return;
            }

            _handle = IntPtr.Zero;
            if (!CloseHandle(handle))
            {
                throw NewWin32Exception("CloseHandle");
            }
        }

        public void Dispose()
        {
            Close();
            GC.SuppressFinalize(this);
        }

        private void EnsureOpen()
        {
            if (_handle == IntPtr.Zero)
            {
                throw new ObjectDisposedException(nameof(JobController));
            }
        }

        private static Win32Exception NewWin32Exception(string operation)
        {
            return new Win32Exception(
                Marshal.GetLastWin32Error(),
                operation + " failed for validation process containment.");
        }
    }
}
