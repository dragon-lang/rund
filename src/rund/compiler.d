module rund.compiler;

immutable string[] DCompilers = ["dmd", "ldmd2", "gdmd"];

string tryFindDCompilerInPath()
{
    import rund.file : which;

    foreach (candidate; DCompilers)
    {
        auto result = which(candidate);
        if (result)
            return result;
    }
    return null;
}
