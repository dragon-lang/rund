module rund.filerebaser;

struct FileRebaser
{
    private string rebaseDir;
    this(string otherCwd)
    {
        import std.path : relativePath, absolutePath;
        import std.file : getcwd;

        auto cwd = getcwd();
        if (cwd == otherCwd)
        {
            this.rebaseDir = null;
        }
        else
        {
            auto relative = relativePath(otherCwd);
            auto absolute = absolutePath(otherCwd);
            this.rebaseDir = (relative.length < absolute.length) ? relative : absolute;
        }
    }
    string correctedPath(string path)
    {
        import std.path : isRooted, buildNormalizedPath;

        if (rebaseDir is null) return path;
        return path.isRooted ? path : buildNormalizedPath(rebaseDir, path);
    }
}
