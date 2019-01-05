#!/usr/bin/env rund
//!importPath src

import std.algorithm : canFind, splitter;
import std.array : Appender, appender;
import std.string : startsWith, split;
import std.format : format;
import std.path : dirName, buildPath, relativePath, pathSeparator;
import std.file : timeLastModified, isFile, exists, copy, FileException;
import std.stdio : write, writeln, writefln, File;
import std.datetime : SysTime;
import std.process : spawnShell, wait, environment, escapeShellCommand;

import rund.common;
import rund.file;
import rund.compiler : tryFindDCompilerInPath;

class SilentException : Exception { this() { super(null); } }

__gshared string FILE_DIR = __FILE_FULL_PATH__.dirName;
string getFilename(C)(const(C)[][] paths...)
{
    return relativePath(buildPath([cast(const(char)[])FILE_DIR] ~ paths));
}

void usage()
{
    write(
`Usage:
  make build
  make install <path>
  make test
`);
}
int main(string[] args)
{
  try { return tryMain(args); }
  catch(SilentException) { return 1; }
}
int tryMain(string[] args)
{
    args = args[1..$];

    {
        size_t newArgsLength = 0;
        scope(exit) args = args[0 .. newArgsLength];
        static string nextArg(string[] args, size_t* i)
        {
            (*i)++;
            if ((*i) >= args.length)
            {
                writefln("Error: option '%s' requires an argument", args[(*i) - 1]);
                throw new SilentException();
            }
            return args[(*i)];
        }
        for (size_t i = 0; i < args.length; i++)
        {
            auto arg = args[i];
            if (!arg.startsWith("-"))
            {
                args[newArgsLength++] = arg;
            }
            else
            {
                writefln("Error: unknown option '%s'", arg);
                return 1;
            }
        }
    }

    if(args.length == 0)
    {
        usage();
        return 1;
    }

    auto command = args[0];
    args = args[1..$];
    if(command == "build")
    {
        auto targetExe = build();
    }
    else if(command == "install")
    {
        auto targetExe = build();
        return install(targetExe);
    }
    else if(command == "test")
    {
        auto targetExe = build();
        test(targetExe, args);
    }
    else
    {
        writefln("Error: unknown command '%s'", command);
        return 1;
    }

    return 0;
}

string build()
{
    auto compiler = tryFindDCompilerInPath();
    if (compiler is null)
    {
        writefln("Error: failed to find a D Compiler");
        return null; // fail
    }
    auto sourceFiles = [
         getFilename("rund.d"),
         getFilename("src", "rund", "common.d"),
         getFilename("src", "rund", "file.d"),
         getFilename("src", "rund", "filerebaser.d"),
         getFilename("src", "rund", "chatty.d"),
         getFilename("src", "rund", "deps.d"),
         getFilename("src", "rund", "directives.d"),
         getFilename("src", "rund", "compiler.d"),
    ];
    auto targetExe = getFilename("bin", "rund" ~ binExt);
    auto targetModifyTime = timeLastModified(targetExe, SysTime.min);
    bool needRebuild = false;
    foreach (sourceFile; sourceFiles)
    {
        if(timeLastModified(sourceFile) > targetModifyTime)
        {
            needRebuild = true;
            break;
        }
    }
    if (!needRebuild)
    {
        writefln("[make] %s is already built", targetExe);
    }
    else
    {
        writefln("[make] building %s...", targetExe);
        auto command = format("%s -g -debug %s", compiler,
            formatQuotedIfSpaces("-of=" ~ targetExe));
        foreach (sourceFile; sourceFiles)
        {
            command ~= format(" %s", formatQuotedIfSpaces(sourceFile));
        }
        run(command);
    }
    return targetExe;
}

int install(string targetExe)
{
    auto programs = appender!(string[])();
    findPrograms(programs, ["dmd"]);
    if(programs.data.length == 0)
    {
        writefln("Error: no 'dmd' compilers were found in the path to install rund to");
        return 1;
    }

    foreach(program; programs.data)
    {
        auto installedRund = buildPath(dirName(program), "rund" ~ binExt);
        static void copyBinary(string from, string to)
        {
            writefln("[make] Installing %s to %s",
                formatQuotedIfSpaces(from),
                formatQuotedIfSpaces(to));
            try
            {
                copy(from, to);
            }
            catch(FileException e)
            {
                version (Windows)
                {
                    import core.sys.windows.winerror : ERROR_SHARING_VIOLATION;
                    if (e.errno == ERROR_SHARING_VIOLATION)
                    {
                        writefln("[make] Error: cannot overwrite rund while it is running: %s", to);
                        writefln("Use the newly built rund to install itself instead: bin\\rund.exe make.d install");
                        throw new SilentException();
                    }
                }
                throw e;
            }
            version(Posix)
            {
                import std.file : getAttributes, setAttributes;
                setAttributes(to, getAttributes(from));
            }
        }
        if (!exists(installedRund))
            copyBinary(targetExe, installedRund);
        else
        {
            if (filesAreEqual(targetExe, installedRund))
                writefln("[make] '%s' exists and is up-to-date", installedRund);
            else
            {
                writefln("[make] '%s' exists but is not up-to-date", installedRund);
                copyBinary(targetExe, installedRund);
            }
        }
    }
    return 0;
}

bool filesAreEqual(const(char)[] filename1, const(char)[] filename2)
{
    auto file1 = File(filename1, "rb");
    auto file2 = File(filename2, "rb");

    ulong sizeUlong = file1.size;
    assert(sizeUlong <= uint.max, "file is too large!");
    uint size = cast(uint)sizeUlong;

    if (size != file2.size)
        return false;

    enum ReadSize = 2048;
    auto buffer1 = new ubyte[ReadSize];
    auto buffer2 = new ubyte[ReadSize];
    auto left = size;
    for (; left > 0;)
    {
        uint readSize = ReadSize;
        if (readSize > left)
            readSize = left;
        {
            auto result = file1.rawRead(buffer1[0 .. readSize]).length;
            assert(result == readSize, format("read '%s' length %s failed, returned %s",
                filename1, readSize, result));
        }
        {
            auto result = file2.rawRead(buffer2[0 .. readSize]).length;
            assert(result == readSize, format("read '%s' length %s failed, returned %s",
                filename2, readSize, result));
        }
        if (buffer1[0 .. readSize] != buffer2[0 .. readSize])
            return false;

        left -= readSize;
    }
    return true;
}

void findPrograms(Appender!(string[]) programs, string[] programNames)
{
    string[] extensions = [""];
    version(Windows) extensions ~= environment["PATHEXT"].split(pathSeparator);
    foreach (envPath; environment["PATH"].splitter(pathSeparator))
    {
        foreach (extension; extensions)
        {
            foreach(programName; programNames)
            {
                string absPath = buildPath(envPath, programName ~ extension);
                if (exists(absPath) && isFile(absPath))
                {
                    programs.put(absPath);
                }
            }
        }
    }
}

private void run(string command)
{
    writefln("[make] [run] %s", command);
    auto pid = spawnShell(command);
    auto result = wait(pid);
    writeln();
    writeln("---------------------------------------------------------------");
    if (result != 0)
    {
        writefln("Error: last shell command failed with exit code %s", result);
        throw new SilentException();
    }
}

void test(const(char)[] rundExe, string[] extraArgs)
{
    run(format("%s %s -g -debug %s %s%s",
        formatQuotedIfSpaces(rundExe),
        formatQuotedIfSpaces("-I" ~ getFilename("src")),
        getFilename("rund_test.d"),
        formatQuotedIfSpaces(rundExe),
        (extraArgs.length == 0) ? "" : escapeShellCommand(extraArgs)));
}