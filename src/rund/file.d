module rund.file;

version (Posix)
{
    enum objExt = ".o";
    enum binExt = "";
    enum libExt = ".a";
    enum dirSeparators = "/";
}
else version (Windows)
{
    enum objExt = ".obj";
    enum binExt = ".exe";
    enum libExt = ".lib";
    enum dirSeparators = "/\\";
}
else
{
    static assert(0, "Unsupported operating system.");
}

struct FileAttributes
{
    private uint attributes;
    private bool _exists;
    bool exists() const { return _exists; }
    bool isFile() const
    {
        import std.file : attrIsFile;
        return _exists && attrIsFile(attributes);
    }
    bool isDir() const
    {
        import std.file : attrIsDir;
        return _exists && attrIsDir(attributes);
    }
}
FileAttributes getFileAttributes(const(char)[] name)
{
    import std.internal.cstring : tempCString;
    import std.format : format;
    import std.file : FileException;
    version(Windows)
    {
        import core.sys.windows.windows : GetFileAttributesW, GetLastError,
            ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND;
        auto attributes = GetFileAttributesW(name.tempCString!wchar());
        if(attributes == 0xFFFFFFFF)
        {
            auto lastError = GetLastError();
            if (lastError == ERROR_FILE_NOT_FOUND || lastError == ERROR_PATH_NOT_FOUND)
                return FileAttributes(0, false);
            throw new FileException(name, format("GetFileAttributesW failed (e=%d)", lastError));
        }
        return FileAttributes(attributes, true);
    }
    else version(Posix)
    {
        import core.stdc.errno : errno, ENOENT;
        import core.sys.posix.sys.stat : stat_t, stat;
        stat_t statbuf = void;
        if(0 != stat(name.tempCString!char(), &statbuf))
        {
            if (errno == ENOENT)
                return FileAttributes(0, false);
            throw new FileException(name, format("stat function failed (e=%d)", errno));
        }
        return FileAttributes(statbuf.st_mode, true);
    }
    else static assert(0);
}

void moveFile(const(char)[] from, const(char)[] to)
{
    static import std.file;
    try
    {
        std.file.rename(from, to);
    }
    catch (std.file.FileException)
    {
        std.file.copy(from, to);
        std.file.remove(from);
    }
}

string which(string path)
{
    import std.algorithm : findAmong, splitter;
    import std.string : split;
    import std.process : environment;
    import std.path : pathSeparator, buildPath, extension;

    if (findAmong(path, dirSeparators).length || getFileAttributes(path).isFile)
    {
        return path;
    }

    string[] extensions = [""];
    version(Windows)
    {
        // TODO: add a test that verifies this works correctly on windows
        if (path.extension is null)
        {
            extensions ~= environment["PATHEXT"].split(pathSeparator);
            // TODO: remove duplicate entries in extensions
        }
    }

    foreach (envPath; environment["PATH"].splitter(pathSeparator))
    {
        foreach (ext; extensions)
        {
            string absPath = buildPath(envPath, path ~ ext);
            if (getFileAttributes(absPath).isFile)
            {
                return absPath;
            }
        }
    }
    return null;
}
