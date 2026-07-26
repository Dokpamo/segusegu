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
            [nameof(NativeMethods.CoreLastErrorJson)] = "lorepia_core_last_error_json",
            [nameof(NativeMethods.CoreVersion)] = "lorepia_core_version",
            [nameof(NativeMethods.CoreHealthCheckJson)] = "lorepia_core_health_check_json",
            [nameof(NativeMethods.CoreInspectImportJson)] = "lorepia_core_inspect_import_json",
            [nameof(NativeMethods.CoreCommitImportJson)] = "lorepia_core_commit_import_json",
            [nameof(NativeMethods.CoreDiscardImport)] = "lorepia_core_discard_import",
            [nameof(NativeMethods.CoreListCharactersJson)] = "lorepia_core_list_characters_json",
            [nameof(NativeMethods.CoreGetCharacterJson)] = "lorepia_core_get_character_json",
            [nameof(NativeMethods.CoreOpenConversationJson)] = "lorepia_core_open_conversation_json",
            [nameof(NativeMethods.CoreListConversationsJson)] = "lorepia_core_list_conversations_json",
            [nameof(NativeMethods.CoreListMessagesJson)] = "lorepia_core_list_messages_json",
            [nameof(NativeMethods.CoreSendMessageJson)] = "lorepia_core_send_message_json",
            [nameof(NativeMethods.CoreCancelGeneration)] = "lorepia_core_cancel_generation",
            [nameof(NativeMethods.CorePollEventsJson)] = "lorepia_core_poll_events_json",
            [nameof(NativeMethods.CoreGetSettingsJson)] = "lorepia_core_get_settings_json",
            [nameof(NativeMethods.CoreUpdateSettingsJson)] = "lorepia_core_update_settings_json",
            [nameof(NativeMethods.CoreListProviderProfilesJson)] = "lorepia_core_list_provider_profiles_json",
            [nameof(NativeMethods.CoreUpsertProviderProfileJson)] = "lorepia_core_upsert_provider_profile_json",
            [nameof(NativeMethods.CoreDeleteProviderProfile)] = "lorepia_core_delete_provider_profile",
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
        var infallible = new HashSet<string>(StringComparer.Ordinal)
        {
            nameof(NativeMethods.AbiVersion),
            nameof(NativeMethods.CoreDestroy),
            nameof(NativeMethods.BufferFree),
        };
        foreach (var methodName in ExpectedEntries.Keys.Except(infallible))
        {
            Assert.Equal(typeof(int), GetMethod(methodName).ReturnType);
        }

        Assert.True(GetMethod(nameof(NativeMethods.CoreCreate))
            .GetParameters()[2]
            .IsOut);

        var bufferedCalls = new[]
        {
            nameof(NativeMethods.CoreLastErrorJson),
            nameof(NativeMethods.CoreVersion),
            nameof(NativeMethods.CoreHealthCheckJson),
            nameof(NativeMethods.CoreInspectImportJson),
            nameof(NativeMethods.CoreCommitImportJson),
            nameof(NativeMethods.CoreListCharactersJson),
            nameof(NativeMethods.CoreGetCharacterJson),
            nameof(NativeMethods.CoreOpenConversationJson),
            nameof(NativeMethods.CoreListConversationsJson),
            nameof(NativeMethods.CoreListMessagesJson),
            nameof(NativeMethods.CoreSendMessageJson),
            nameof(NativeMethods.CorePollEventsJson),
            nameof(NativeMethods.CoreGetSettingsJson),
            nameof(NativeMethods.CoreListProviderProfilesJson),
            nameof(NativeMethods.CoreUpsertProviderProfileJson),
        };
        foreach (var methodName in bufferedCalls)
        {
            Assert.True(GetMethod(methodName).GetParameters()[^1].IsOut);
        }
    }

    [Fact]
    public void Utf8Arrays_UseExplicitLengthParameters()
    {
        var methods = new[]
        {
            nameof(NativeMethods.CoreCreate),
            nameof(NativeMethods.CoreInspectImportJson),
            nameof(NativeMethods.CoreCommitImportJson),
            nameof(NativeMethods.CoreDiscardImport),
            nameof(NativeMethods.CoreGetCharacterJson),
            nameof(NativeMethods.CoreOpenConversationJson),
            nameof(NativeMethods.CoreListMessagesJson),
            nameof(NativeMethods.CoreSendMessageJson),
            nameof(NativeMethods.CoreCancelGeneration),
            nameof(NativeMethods.CoreUpdateSettingsJson),
            nameof(NativeMethods.CoreUpsertProviderProfileJson),
            nameof(NativeMethods.CoreDeleteProviderProfile),
        };

        foreach (var methodName in methods)
        {
            var parameters = GetMethod(methodName).GetParameters();
            foreach (var (parameter, index) in parameters.Select((value, index) => (value, index)))
            {
                if (parameter.ParameterType != typeof(byte[]))
                {
                    continue;
                }

                var marshal = parameter.GetCustomAttribute<MarshalAsAttribute>();
                Assert.NotNull(marshal);
                Assert.Equal(UnmanagedType.LPArray, marshal.Value);
                Assert.InRange(marshal.SizeParamIndex, (short)(index + 1), (short)(parameters.Length - 1));
                Assert.Equal(typeof(nuint), parameters[marshal.SizeParamIndex].ParameterType);
            }
        }
    }

    private static MethodInfo GetMethod(string name) =>
        typeof(NativeMethods).GetMethod(
            name,
            BindingFlags.Static | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException($"Missing native method {name}.");
}
