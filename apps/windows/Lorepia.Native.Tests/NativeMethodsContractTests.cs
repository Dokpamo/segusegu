using Lorepia.Native.Interop;
using System.Reflection;
using System.Runtime.InteropServices;

namespace Lorepia.Native.Tests;

public sealed class NativeMethodsContractTests
{
    private static readonly IReadOnlyDictionary<string, string> ExpectedEntries =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            [nameof(NativeMethods.AbiVersion)] = "lorepia_abi_version",
            [nameof(NativeMethods.CoreCreate)] = "lorepia_core_create",
            [nameof(NativeMethods.CoreDestroy)] = "lorepia_core_destroy",
            [nameof(NativeMethods.CoreVersion)] = "lorepia_core_version",
            [nameof(NativeMethods.CoreHealthCheckJson)] = "lorepia_core_health_check_json",
            [nameof(NativeMethods.CoreListCharactersJson)] = "lorepia_core_list_characters_json",
            [nameof(NativeMethods.BufferFree)] = "lorepia_buffer_free",
        };

    [Fact]
    public void PInvokeMethods_UseExactCdeclContract()
    {
        var methods = typeof(NativeMethods)
            .GetMethods(BindingFlags.Static | BindingFlags.NonPublic)
            .Where(method => method.GetCustomAttribute<DllImportAttribute>() is not null)
            .ToDictionary(method => method.Name, StringComparer.Ordinal);

        Assert.Equal(ExpectedEntries.Count, methods.Count);

        foreach (var (methodName, entryPoint) in ExpectedEntries)
        {
            var attribute = methods[methodName].GetCustomAttribute<DllImportAttribute>();

            Assert.NotNull(attribute);
            Assert.Equal(NativeMethods.LibraryName, attribute.Value);
            Assert.Equal(entryPoint, attribute.EntryPoint);
            Assert.Equal(CallingConvention.Cdecl, attribute.CallingConvention);
            Assert.True(attribute.ExactSpelling);
        }
    }

    [Fact]
    public void FallibleCalls_ReturnStatusAndUseOutParameters()
    {
        Assert.Equal(typeof(int), GetMethod(nameof(NativeMethods.CoreCreate)).ReturnType);
        Assert.Equal(typeof(int), GetMethod(nameof(NativeMethods.CoreVersion)).ReturnType);
        Assert.Equal(typeof(int), GetMethod(nameof(NativeMethods.CoreHealthCheckJson)).ReturnType);
        Assert.Equal(typeof(int), GetMethod(nameof(NativeMethods.CoreListCharactersJson)).ReturnType);

        Assert.True(GetMethod(nameof(NativeMethods.CoreCreate))
            .GetParameters()[2]
            .IsOut);
        Assert.True(GetMethod(nameof(NativeMethods.CoreVersion))
            .GetParameters()[1]
            .IsOut);
        Assert.True(GetMethod(nameof(NativeMethods.CoreHealthCheckJson))
            .GetParameters()[1]
            .IsOut);
        Assert.True(GetMethod(nameof(NativeMethods.CoreListCharactersJson))
            .GetParameters()[1]
            .IsOut);
    }

    private static MethodInfo GetMethod(string name) =>
        typeof(NativeMethods).GetMethod(
            name,
            BindingFlags.Static | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException($"Missing native method {name}.");
}
