using Lorepia.Native.Interop;
using System.Text.Json;
using System.Threading;

namespace Lorepia.Native;

public sealed class CoreClient : IDisposable
{
    public const uint SupportedAbiVersion = 1;

    private readonly INativeApi nativeApi;
    private readonly SafeCoreHandle core;
    private int disposed;

    private CoreClient(
        INativeApi nativeApi,
        SafeCoreHandle core,
        uint abiVersion)
    {
        this.nativeApi = nativeApi;
        this.core = core;
        AbiVersion = abiVersion;
    }

    public uint AbiVersion { get; }

    public static CoreClient Open(string dataRoot)
    {
        return Open(PInvokeNativeApi.Instance, dataRoot);
    }

    internal static CoreClient Open(
        INativeApi nativeApi,
        string dataRoot)
    {
        ArgumentNullException.ThrowIfNull(nativeApi);
        ArgumentException.ThrowIfNullOrWhiteSpace(dataRoot);

        if (!Path.IsPathFullyQualified(dataRoot))
        {
            throw new ArgumentException(
                "The LorePia data root must be an absolute path.",
                nameof(dataRoot));
        }

        var normalizedDataRoot = Path.GetFullPath(dataRoot);
        var configurationJson = JsonSerializer.SerializeToUtf8Bytes(
            new CoreConfiguration(normalizedDataRoot));

        var abiVersion = nativeApi.GetAbiVersion();
        if (abiVersion != SupportedAbiVersion)
        {
            throw new CoreInteropException(
                $"Unsupported LorePia C ABI version {abiVersion}; expected {SupportedAbiVersion}.");
        }

        var core = nativeApi.CreateCore(configurationJson);
        if (core.IsInvalid)
        {
            core.Dispose();
            throw new CoreInteropException(
                "The native core could not create a core handle.");
        }

        return new CoreClient(nativeApi, core, abiVersion);
    }

    public string GetCoreVersion()
    {
        ThrowIfDisposed();

        using var buffer = nativeApi.GetCoreVersion(core);
        var version = buffer.ReadUtf8();
        if (string.IsNullOrWhiteSpace(version))
        {
            throw new CoreInteropException(
                "The native core returned an empty version string.");
        }

        return version;
    }

    public CoreHealth GetHealthCheck()
    {
        ThrowIfDisposed();

        using var buffer = nativeApi.GetHealthCheckJson(core);
        return CoreHealthMapper.Parse(buffer.ReadUtf8());
    }

    public IReadOnlyList<CharacterSummary> ListCharacters()
    {
        ThrowIfDisposed();

        using var buffer = nativeApi.GetCharactersJson(core);
        return CharacterSummaryMapper.Parse(buffer.ReadUtf8());
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) == 0)
        {
            core.Dispose();
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(
            Volatile.Read(ref disposed) != 0,
            this);
    }

    private sealed record CoreConfiguration(
        [property: System.Text.Json.Serialization.JsonPropertyName("data_root")]
        string DataRoot);
}
