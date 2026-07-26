using Lorepia.Native.Interop;
using System.Runtime.InteropServices;
using System.Text;

namespace Lorepia.Native.Tests;

internal sealed class FakeNativeApi : INativeApi
{
    internal uint AbiVersion { get; set; } = CoreClient.SupportedAbiVersion;

    internal string Version { get; set; } = "0.1.0-test";

    internal string HealthJson { get; set; } =
        """
        {
          "core_version": "0.1.0-test",
          "database_open": true,
          "schema_version": 3,
          "data_root_writable": true,
          "staging_writable": true,
          "recovery_pending": false,
          "active_jobs": 2
        }
        """;

    internal string CharactersJson { get; set; } =
        """
        [
          {
            "id": "character-1",
            "name": "테스트 캐릭터",
            "description": "합성 테스트 데이터",
            "source_hash": "abc123",
            "avatar_asset_hash": null,
            "created_at": "2026-07-26T00:00:00Z",
            "future_field": "ignored"
          }
        ]
        """;

    internal string? ConfigurationJson { get; private set; }

    internal int CreateCount { get; private set; }

    internal int DestroyCount { get; private set; }

    internal int BufferFreeCount { get; private set; }

    public uint GetAbiVersion() => AbiVersion;

    public SafeCoreHandle CreateCore(byte[] configurationJson)
    {
        ArgumentNullException.ThrowIfNull(configurationJson);
        CreateCount++;
        ConfigurationJson = Encoding.UTF8.GetString(configurationJson);
        return new SafeCoreHandle(
            new IntPtr(0x1234),
            _ => DestroyCount++);
    }

    public NativeBuffer GetCoreVersion(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(Version);
    }

    public NativeBuffer GetHealthCheckJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(HealthJson);
    }

    public NativeBuffer GetCharactersJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(CharactersJson);
    }

    private NativeBuffer CreateBuffer(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        var pointer = Marshal.AllocHGlobal(bytes.Length);
        if (bytes.Length > 0)
        {
            Marshal.Copy(bytes, 0, pointer, bytes.Length);
        }

        return new NativeBuffer(
            new NativeBufferValue(pointer, checked((nuint)bytes.Length)),
            value =>
            {
                BufferFreeCount++;
                Marshal.FreeHGlobal(value.Pointer);
            });
    }
}
