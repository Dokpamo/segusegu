using Windows.Storage;

namespace Lorepia.App.Platform;

internal sealed record StagedTransportFile(
    string Name,
    string Path,
    ulong Size);

internal static class BoundedStagingCopier
{
    internal const long MaxBytes = 128L * 1024 * 1024;

    internal static async Task<StagedTransportFile> CopyAsync(
        StorageFile source,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(source);
        var stagingRoot = WindowsDataRoot.GetOrCreateTransportStaging();
        var extension = SanitizeExtension(Path.GetExtension(source.Name));
        var targetPath = Path.Combine(
            stagingRoot,
            $"{Guid.NewGuid():N}{extension}");

        try
        {
            await using var input = await source.OpenStreamForReadAsync();
            await using var output = new FileStream(
                targetPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                bufferSize: 64 * 1024,
                useAsync: true);
            var size = await BoundedStreamCopier.CopyAsync(
                input,
                output,
                MaxBytes,
                cancellationToken);
            await output.FlushAsync(cancellationToken);
            return new StagedTransportFile(
                source.Name,
                targetPath,
                checked((ulong)size));
        }
        catch
        {
            TryDelete(targetPath);
            throw;
        }
    }

    internal static void TryDelete(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        try
        {
            File.Delete(path);
        }
        catch (Exception exception) when (
            exception is IOException
            or UnauthorizedAccessException)
        {
            // The core owns any accepted snapshot; transport cleanup is best effort.
        }
    }

    internal static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB"];
        var value = (double)bytes;
        var unitIndex = 0;
        while (value >= 1024 && unitIndex < units.Length - 1)
        {
            value /= 1024;
            unitIndex++;
        }

        return $"{value:0.##} {units[unitIndex]}";
    }

    private static string SanitizeExtension(string extension)
    {
        if (string.IsNullOrWhiteSpace(extension)
            || extension.Length > 16
            || extension.Any(character =>
                !char.IsAsciiLetterOrDigit(character) && character != '.'))
        {
            return ".bin";
        }

        return extension.ToLowerInvariant();
    }
}
