<#
  File-lock detection via the Windows Restart Manager.

  Reports which processes currently hold a file open. It never terminates
  anything: closing an application can discard unsaved work, so termination is
  left to the user.

  Dot-source from a script:
    . (Join-Path $PSScriptRoot 'lib\locks.ps1')
#>

$script:LockTypeLoaded = $false

function Initialize-LockType {
  if ($script:LockTypeLoaded) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class DiskCleanupLocks
{
    [StructLayout(LayoutKind.Sequential)]
    private struct RM_UNIQUE_PROCESS
    {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmEndSession(uint pSessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
        uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
        [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    public static string[] GetLockers(string path)
    {
        uint handle;
        string key = Guid.NewGuid().ToString();
        if (RmStartSession(out handle, 0, key) != 0) return new string[0];

        try
        {
            string[] files = new string[] { path };
            if (RmRegisterResources(handle, 1, files, 0, null, 0, null) != 0) return new string[0];

            uint needed = 0;
            uint count = 0;
            uint reasons = 0;
            int rv = RmGetList(handle, out needed, ref count, null, ref reasons);
            if (rv != 234 || needed == 0) return new string[0]; // 234 = ERROR_MORE_DATA

            var infos = new RM_PROCESS_INFO[needed];
            count = needed;
            rv = RmGetList(handle, out needed, ref count, infos, ref reasons);
            if (rv != 0) return new string[0];

            var result = new List<string>();
            for (int i = 0; i < count; i++)
            {
                string name = infos[i].strAppName;
                if (String.IsNullOrEmpty(name)) name = "unknown";
                result.Add(infos[i].Process.dwProcessId + "|" + name);
            }
            return result.ToArray();
        }
        finally
        {
            RmEndSession(handle);
        }
    }
}
'@ -ErrorAction SilentlyContinue
  $script:LockTypeLoaded = $true
}

<#
  Return the processes holding a file open. Empty array means "no lock detected"
  or "the API is unavailable"; check Available to tell them apart.
#>
function Get-FileLockers {
  param([string]$Path)

  Initialize-LockType
  $result = [pscustomobject]@{
    Path      = $Path
    Available = $script:LockTypeLoaded
    Locked    = $false
    Processes = @()
  }

  if (-not $script:LockTypeLoaded) { return $result }
  try {
    $raw = [DiskCleanupLocks]::GetLockers($Path)
    if ($raw -and $raw.Count -gt 0) {
      $result.Locked = $true
      $result.Processes = @($raw | ForEach-Object {
          $parts = $_ -split '\|', 2
          [pscustomobject]@{ Pid = [int]$parts[0]; Name = $parts[1] }
        })
    }
  } catch { }
  return $result
}
