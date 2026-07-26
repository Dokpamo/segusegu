using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

namespace Lorepia.Native.Interop;

internal static class NativeLibraryResolver
{
    private static int initialized;

    internal static void EnsureRegistered()
    {
        if (Interlocked.Exchange(ref initialized, 1) != 0)
        {
            return;
        }

        NativeLibrary.SetDllImportResolver(
            typeof(NativeMethods).Assembly,
            ResolveLibrary);
    }

    private static IntPtr ResolveLibrary(
        string libraryName,
        Assembly assembly,
        DllImportSearchPath? searchPath)
    {
        if (!string.Equals(libraryName, NativeMethods.LibraryName, StringComparison.Ordinal))
        {
            return IntPtr.Zero;
        }

        if (!OperatingSystem.IsWindows())
        {
            throw new DllNotFoundException(
                "The LorePia native core can only be loaded by this binding on Windows.");
        }

        var fullPath = Path.GetFullPath(
            Path.Combine(AppContext.BaseDirectory, "lorepia_core.dll"));

        if (!File.Exists(fullPath))
        {
            throw new DllNotFoundException(
                $"The required LorePia core DLL was not found at the deterministic path '{fullPath}'.");
        }

        Trace.TraceInformation("Loading LorePia native core from {0}", fullPath);
        return NativeLibrary.Load(fullPath, assembly, searchPath);
    }
}
