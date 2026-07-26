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
}
