module rund.directives;

class SourceDirectiveException : Exception
{
    this(string msg, string file, size_t line, Exception inner = null)
    {
        super(msg, file, line, inner);
    }
}

/**
Process directives from `sourceFilename`.
*/
void processDirectivesFromFile(T)(T compiler, string sourceFilename)
{
    import std.stdio : File;

    auto sourceFile = File(sourceFilename, "r");
    static struct LineReader
    {
        File file;
        auto readln()
        {
            return file.readln().stripNewline;
        }
    }
    processDirectivesFromReader!(T)(compiler, sourceFilename, &LineReader(sourceFile).readln);
}
/// ditto
void processDirectivesFromReader(T, R)(T compiler, string sourceFilename, R lineReader)
{
    import std.algorithm : skipOver;
    import std.string : indexOf, startsWith;
    import std.format : format;
    import std.path : dirName;
    import std.process : environment;
    import rund.filerebaser;
    import rund.file : getFileAttributes;

    auto line = lineReader();
    size_t lineno = 1;
    auto fileRebaser = FileRebaser(sourceFilename.dirName);

    // skip shebang line
    if (line.startsWith("#!"))
    {
        line = lineReader();
        lineno++;
    }
    for (;;)
    {
        auto args = line;
        if (!args.skipOver("//!"))
            return;
        auto directive = peel(&args);

        if (directive == "importPath")
        {
            auto path = fileRebaser.correctedPath(args);
            auto attr = getFileAttributes(path);
            if (!attr.exists)
                throw new SourceDirectiveException(format("import path '%s' does not exist", path), sourceFilename, lineno);
            compiler.put("-I=" ~ path);
        }
        // require a pattern because rund will always include "-i" by default so there's not reason to -i without an argument
        else if (directive == "includeImports")
            compiler.put("-i=" ~ args);
        else if (directive == "importFilenamePath")
            compiler.put("-J=" ~ fileRebaser.correctedPath(args));
        else if (directive == "library")
            compiler.put(fileRebaser.correctedPath(args));
        else if (directive == "version")
            compiler.put("-version=" ~ args);
        else if (directive == "env")
        {
            auto indexOfEquals = args.indexOf('=');
            if (indexOfEquals < 0) throw new SourceDirectiveException(format(
                "Error: compiler directive `%s` requires argument with format VAR=VALUE", line), sourceFilename, lineno);
            environment[args[0 .. indexOfEquals]] = args[indexOfEquals + 1 .. $];
        }
        else if (directive == "unittest")
            compiler.put("-unittest");
        else if (directive == "betterC")
            compiler.put("-betterC");
        else if (directive == "debugSymbols")
            compiler.put("-g");
        else if (directive == "debug")
            compiler.put("-debug");
        else if (directive == "noConfigFile")
            compiler.put("-conf=");
        else throw new SourceDirectiveException(format(
            "unknown compiler directive `%s`", line), sourceFilename, lineno);

        line = lineReader();
        lineno++;
    }
}

T peel(T)(T* stringRef)
{
    import std.string : indexOf;

    auto str = *stringRef;
    auto spaceIndex = str.indexOf(' ');
    if (spaceIndex == -1)
    {
        *stringRef = null;
        return str;
    }
    *stringRef = str[spaceIndex + 1 .. $];
    return str[0 .. spaceIndex];
}

auto stripNewline(inout(char)[] line)
{
    while (line.length > 0 && (line[$ - 1] == '\n' || line[$ - 1] == '\r'))
        line.length--;
    return line;
}
