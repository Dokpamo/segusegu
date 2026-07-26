namespace Lorepia.App.Platform;

internal static class WindowsDataRoot
{
    internal static string GetOrCreate()
    {
        var localApplicationData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localApplicationData))
        {
            throw new InvalidOperationException(
                "Windows did not provide a LocalApplicationData directory.");
        }

        var dataRoot = Path.GetFullPath(
            Path.Combine(localApplicationData, "LorePia"));
        Directory.CreateDirectory(dataRoot);
        return dataRoot;
    }

    internal static string GetOrCreateTransportStaging()
    {
        var staging = Path.Combine(GetOrCreate(), "transport-staging");
        Directory.CreateDirectory(staging);
        foreach (var path in Directory.EnumerateFiles(
                     staging,
                     "*",
                     SearchOption.TopDirectoryOnly))
        {
            try
            {
                File.Delete(path);
            }
            catch (Exception exception) when (
                exception is IOException
                or UnauthorizedAccessException)
            {
                // Another process may still own an actively staged file.
            }
        }

        return staging;
    }
}
