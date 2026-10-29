# Pin ancestors during mutation so a checked directory cannot be replaced by a junction.
if (-not ('QdfPathLease' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public sealed class QdfPathLease : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct Info {
        public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind, ref int value, uint size);
    readonly List<SafeFileHandle> handles = new List<SafeFileHandle>();
    static Info Inspect(SafeFileHandle handle) {
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        Info info;
        if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if ((info.Attributes & 0x400) != 0) throw new IOException("Reparse points are not allowed.");
        return info;
    }
    public QdfPathLease(string file) {
        try {
            string parent = Path.GetDirectoryName(Path.GetFullPath(file));
            var chain = new Stack<string>();
            while (!String.IsNullOrEmpty(parent)) { chain.Push(parent); parent = Path.GetDirectoryName(parent); }
            while (chain.Count > 0) {
                var handle = CreateFile(chain.Pop(), 0x80000000, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
                handles.Add(handle);
                var info = Inspect(handle);
                if ((info.Attributes & 0x10) == 0) throw new IOException("Ancestor is not a directory.");
            }
        } catch { Dispose(); throw; }
    }
    public static void DeleteVerified(string file, long size, long writeTime) {
        // Delete the inspected handle, not a second path lookup. Deny concurrent writers.
        using (var handle = CreateFile(file, 0x10080, 1, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
            var info = Inspect(handle);
            long actualSize = ((long)info.SizeHigh << 32) | info.SizeLow;
            long actualTime = ((long)info.Write.dwHighDateTime << 32) | (uint)info.Write.dwLowDateTime;
            if ((info.Attributes & 0x10) != 0 || actualSize != size || actualTime != writeTime)
                throw new IOException("Candidate changed after scanning.");
            int disposition = 1;
            if (!SetFileInformationByHandle(handle, 4, ref disposition, 4)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
    public void Dispose() { for (int i=handles.Count-1; i>=0; --i) handles[i].Dispose(); handles.Clear(); }

    // Fast path: the executor only calls this after confirming every file inside
    // the subtree was a scanned candidate, so the whole subtree can be removed with
    // a single recursive delete. Nested directories are fine; a reparse point is not
    // (it could relocate deletion outside the verified boundary), so bail on one.
    static SafeFileHandle OpenPath(string path) {
        var handle = CreateFile(path, 0x10080, 1, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        Inspect(handle);
        return handle;
    }
    static void RejectReparseSubtree(string directory) {
        foreach (var entry in new System.IO.DirectoryInfo(directory).EnumerateFileSystemInfos()) {
            if (((uint)entry.Attributes & 0x400u) != 0) throw new IOException("Subtree contains a reparse point.");
            string fullPath = System.IO.Path.Combine(directory, entry.Name);
            using (OpenPath(fullPath)) { }
            if (((uint)entry.Attributes & 0x10u) != 0) RejectReparseSubtree(fullPath);
        }
    }
    public static void DeleteDirectoryVerified(string directory) {
        var lease = new QdfPathLease(directory);
        using (lease) {
            RejectReparseSubtree(directory);
            System.IO.Directory.Delete(directory, true);
        }
    }
}
'@
}
