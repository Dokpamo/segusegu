namespace Lorepia.App.Platform;

internal static class BoundedStreamCopier
{
    internal static async Task<long> CopyAsync(
        Stream input,
        Stream output,
        long maxBytes,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(output);
        if (maxBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maxBytes));
        }

        var buffer = new byte[64 * 1024];
        long total = 0;
        while (true)
        {
            var read = await input.ReadAsync(
                buffer.AsMemory(),
                cancellationToken);
            if (read == 0)
            {
                return total;
            }

            total = checked(total + read);
            if (total > maxBytes)
            {
                throw new InvalidDataException(
                    "The selected file exceeds the bounded staging limit.");
            }

            await output.WriteAsync(
                buffer.AsMemory(0, read),
                cancellationToken);
        }
    }
}
