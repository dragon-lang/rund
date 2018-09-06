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
        auto command = line;
        if (!command.skipOver("//!"))
            return;

        if (command.skipOver("importPath "))
        {
            auto path = fileRebaser.correctedPath(command);
            auto attr = getFileAttributes(path);
            if (!attr.exists)
                throw new SourceDirectiveException(format("import path '%s' does not exist", path), sourceFilename, lineno);
            compiler.put("-I=" ~ path);
        }
        else if (command.skipOver("importFilenamePath "))
            compiler.put("-J=" ~ fileRebaser.correctedPath(command));
        else if (command.skipOver("library "))
            compiler.put(fileRebaser.correctedPath(command));
        else if (command.skipOver("version "))
            compiler.put("-version=" ~ command);
        else if (command.skipOver("env "))
        {
            auto indexOfEquals = command.indexOf('=');
            if (indexOfEquals < 0) throw new SourceDirectiveException(format(
                "Error: compiler directive `%s` requires argument with format VAR=VALUE", line), sourceFilename, lineno);
            environment[command[0 .. indexOfEquals]] = command[indexOfEquals + 1 .. $];
        }
        else if (command.skipOver("unittest"))
            compiler.put("-unittest");
        else if (command.skipOver("betterC"))
            compiler.put("-betterC");
        else if (command.skipOver("noConfigFile"))
            compiler.put("-conf=");
        else throw new SourceDirectiveException(format(
            "unknown compiler directive `%s`", line), sourceFilename, lineno);

        line = lineReader();
        lineno++;
    }
}

auto stripNewline(inout(char)[] line)
{
    while (line.length > 0 && (line[$ - 1] == '\n' || line[$ - 1] == '\r'))
        line.length--;
    return line;
}
