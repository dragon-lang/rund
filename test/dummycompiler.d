import std.array;
import std.string;
import std.conv;
import std.algorithm;
import std.format;
import std.ascii;
import std.path;
import std.file;
import std.stdio;

Char[] skipWhitespace(Char)(Char[] str)
{
    while (str.length > 0 && str[0].isWhite)
        str = str[1 .. $];
    return str;
}
Char[] until(Char)(Char[] str, char needle)
{
    auto index = str.indexOf(needle);
    if (index < 0)
        throw new Exception(format("expected string to contain '%s'", needle));
    return str[0 .. index];
}
Char[] until(alias Cond, Char)(Char[] str) if (is(typeof(Cond(str[0]))))
{
    foreach (i, c; str)
        if (Cond(c))
            return str[0 .. i];
    return str;
}

void parseLine(T)(T appender, string line)
{
    for (;;)
    {
        line = line.skipWhitespace;
        if (line.length == 0)
            break;
        if (line[0] == '"') {
            line = line[1 .. $];
            const s = line.until('"');
            appender.put(s);
            line = line[s.length + 1 .. $];
        } else {
            const s = line.until!isWhite;
            appender.put(s);
            line = line[s.length .. $];
        }
    }
}

__gshared string outputFile = null;

void parse(string[] args)
{
    foreach (arg; args)
    {
        writefln("arg '%s'", arg);
        if (arg.startsWith("@"))
        {
            auto fileArgs = appender!(string[])();
            foreach (line; File(arg[1 .. $], "r").byLine)
            {
                parseLine(fileArgs, line.idup);
            }
            parse(fileArgs.data);
        }
        else if (arg.skipOver("-of="))
        {
            outputFile = arg;
            writefln("OUTPUT FILE '%s'", outputFile);
        }
        else if (outputFile is null)
        {
            if (arg.endsWith(".d"))
            {
                outputFile = arg[0 .. $-2];
            }
        }
    }
}
int main(string[] args)
{
    writefln("Dummy Compiler '%s'", args[0]);
    parse(args[1 .. $]);
    if (outputFile is null)
    {
        writefln("Running in dummy exe mode (not compiler mode)");
    }
    else
    {
        // compiler mode, copy ourself to the output file
        mkdirRecurse(outputFile.dirName);
        copy(args[0], outputFile);
        version (Posix)
        {
            setAttributes(outputFile, octal!775);
        }
    }
    return 0;
}
