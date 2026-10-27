namespace ClaudeSwitcher.Admin;

public static class AdminApplication
{
    public static int Run(IReadOnlyList<string>? args, AdminContext context, TextWriter output)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(output);

        if (!AdminRequest.TryParse(args, out var request, out var parseError))
        {
            output.WriteLine(parseError);
            return (int)AdminExitCode.InvalidArguments;
        }

        try
        {
            var result = context.Execute(request!);
            if (!result.Success)
            {
                output.WriteLine(result.Error);
            }

            return (int)result.ExitCode;
        }
        catch (Exception)
        {
            output.WriteLine("fixed operation failed; completed earlier steps may remain applied");
            return (int)AdminExitCode.OperationFailed;
        }
    }
}
