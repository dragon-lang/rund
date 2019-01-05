module rund.compiler;

immutable string[] DCompilers = ["dmd", "ldmd2", "gdmd"];

string tryFindDCompilerInPath()
{
    import rund.file : whichMultiple;
    return whichMultiple(DCompilers);
}
