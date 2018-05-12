#!/usr/bin/env rund
//!importPath src

import std.algorithm : canFind, splitter;
import std.array : Appender, appender;
import std.string : startsWith, split;
import std.format : format;
import std.path : dirName, buildPath, relativePath, pathSeparator;
import std.file : timeLastModified, isFile, exists, copy;
import std.stdio : write, writeln, writefln;
import std.datetime : SysTime;
import std.process : spawnShell, wait, environment, escapeShellCommand;

import rund.common;

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
    auto sourceFiles = [
         getFilename("src", "rund", "main.d"),
         getFilename("src", "rund", "common.d"),
         getFilename("src", "rund", "chatty.d"),
         getFilename("src", "rund", "deps.d"),
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
        auto command = format("dmd -g -debug %s",
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
            copy(from, to);
            version(Posix)
            {
                import std.file : getAttributes, setAttributes;
                setAttributes(to, getAttributes(from));
            }
        }
        if(exists(installedRund))
        {
            // TODO: check if that rund is the same as this one
            writefln("[make] '%s' exists (TODO: check if it is up-to-date, for now just overrwrite)", installedRund);
            copyBinary(targetExe, installedRund);
        }
        else
        {
            copyBinary(targetExe, installedRund);
        }
    }
    return 0;
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
    run(format("%s -g -debug %s %s %s%s",
        formatQuotedIfSpaces(rundExe),
        formatQuotedIfSpaces("-I" ~ getFilename("src")),
        getFilename("test", "rund_test.d"),
        formatQuotedIfSpaces(rundExe),
        (extraArgs.length == 0) ? "" : escapeShellCommand(extraArgs)));
}