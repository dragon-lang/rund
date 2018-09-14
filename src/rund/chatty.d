module rund.chatty;

import std.format : format;
import std.stdio : writef, writefln, writeln, stderr;

import rund.common;
import rund.file;
import rund.filerebaser : FileRebaser;

__gshared bool chatty;
__gshared bool dryRun;

pragma(inline) void yapf(string file = __FILE__, size_t line = __LINE__, T...)(string format, T args)
{
    yapfWithLoc(file, line, format, args);
}
private void yapfWithLoc(T...)(string file, size_t line, string format, T args)
{
    if(chatty)
    {
        debug stderr.writef("%s(%s) ", file, line);
        writefln(format, args);
    }
}
pragma(inline) void yap(string file = __FILE__, size_t line = __LINE__, T...)(auto ref T stuff)
{
    yapWithLoc(file, line, stuff);
}
private void yapWithLoc(T...)(string file, size_t line, auto ref T stuff)
{
    if(chatty)
    {
        debug stderr.writeln(format("%s(%s) ", file, line), stuff);
        else stderr.writeln(stuff);
    }
}

/**
Update an empty file's timestamp.
*/
private void writeEmptyFile(string name)
{
    import std.file : write;
    write(name, "");
}

/**
Returns true if `name` exists and is a file.
*/
private bool existsAsFile(string name)
{
    return getFileAttributes(name).isFile;
}

/**
Get the corrected path from `rebaser` but yap the result.
*/
string yapCorrectedPath(FileRebaser rebaser, string logName, string path)
{
    auto result = rebaser.correctedPath(path);
    yapf("%s %s => %s", logName, path.formatQuotedIfSpaces, result.formatQuotedIfSpaces);
    return result;
}

/**
Used to wrap operations that should be logged and potentially
disabled via `dryRun`. Append the string "IfLive" to only execute on
a non dry run (note, it will still be logged in this case).
*/
struct Chatty
{
    static auto opDispatch(string func, string file = __FILE__, size_t line = __LINE__, T...)(T args)
    {
        import std.file;
        import std.algorithm : among;
        import std.string : endsWith;

        static if (func.endsWith("IfLive"))
        {
            enum fileFunc = func[0 .. $ - "IfLive".length];
            enum skipOnDryRun = true;
        }
        else
        {
            enum fileFunc = func;
            enum skipOnDryRun = false;
        }

        static if (fileFunc.among("copy", "rename"))
        {
            enum logReturn = false;
            yap!(file, line)(fileFunc, " ", args[0], " ", args[1]);
        }
        else static if (fileFunc.among("remove", "mkdirRecurse", "rmdirRecurse", "dirEntries", "write",
            "writeEmptyFile", "readText", "exists", "timeLastModified", "isFile", "isDir", "existsAsFile", "getFileAttributes", "readLink"))
        {
            enum logReturn = false;
            yap!(file, line)(fileFunc, " ", args[0]);
        }
        else static if (fileFunc.among("which"))
        {
            enum logReturn = true;
        }
        else static assert(0, "Filesystem.opDispatch has not implemented " ~ fileFunc);

        static if (skipOnDryRun)
        {
            if (dryRun)
                return;
        }

        static if (logReturn)
        {
            mixin("auto result = " ~ fileFunc ~ "(args);");
            yapf!(file, line)("%s %s => %s", fileFunc, args[0].formatQuotedIfSpaces, result.formatQuotedIfSpaces);
            return result;
        }
        else
        {
            mixin("return " ~ fileFunc ~ "(args);");
        }
    }
}

