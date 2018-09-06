#!/usr/bin/env rund
//!importPath src
/*
 *  Copyright (C) 2008 by Andrei Alexandrescu
 *
 *  Based on rdmd which was
 *  Written by Andrei Alexandrescu, www.erdani.org
 *  based on an idea by Georg Wrede
 *  Featuring improvements suggested by Christopher Wright
 *  Windows port using bug fixes and suggestions by Adam Ruppe
 *
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module __none;

// TODO: limit number of cached entries in the cache directory
// TODO: maybe provide an option to clean the cache?

import core.stdc.stdlib : exit;

import std.typecons : Flag, Yes, No;
import std.exception : collectException, enforce;
import std.algorithm : canFind, map, skipOver, splitter;
import std.range : chain, only;
import std.array : array, appender;
static import std.string;
import std.string : startsWith, endsWith, toStringz, representation, join, lastIndexOf, replace;
import std.format : format;
import std.digest.md : MD5, toHexString;
import std.path : buildPath, buildNormalizedPath, dirName, baseName, isAbsolute, pathSeparator, dirSeparator, absolutePath;
import std.datetime : SysTime, Clock;
import std.process : thisProcessID, escapeShellCommand, escapeWindowsArgument,
                     environment, spawnProcess, wait;
// Only import std.file functions that don't need to be logged
import std.file : tempDir, FileException, thisExePath;
import std.stdio : stderr, stdout, stdin,
                   write, writeln, writef, writefln, File;

import rund.common;
import rund.file;
import rund.chatty;
import rund.deps;
import rund.directives;

private string cacheDirOverride;

version (DigitalMars)
    private enum defaultCompiler = "dmd";
else version (GNU)
    private enum defaultCompiler = "gdmd";
else version (LDC)
    private enum defaultCompiler = "ldmd2";
else
    static assert(false, "Unknown compiler");

void usage()
{
    writef(
`Usage: rund [rund/compiler options]... program.d [program options]...

Builds and runs a D program. Rund/Compiler options are separated from program options
by the first source file ending in ".d".

Example: rund -release myprog.d -myprogarg 5

In addition to all the compiler options, rund also recognizes:
  --compiler=<comp>    use the specified compiler (default=` ~ defaultCompiler ~ `)
  --force              ignore prebuilt cache and build no matter what
  --chatty             print information about what rund is doing
  --build-only         build but do not run
  --dry-run            do not build, just print actions
  --pass=<arg>.d       pass an argument ending in ".d" to rund or the compiler.
  --cache=<dir>        override default cache directory %s
`, buildDefaultCacheDir().formatQuotedIfSpaces);
}

string isValueArg(string arg, string argName, Flag!"canBeEmpty" canBeEmpty)
{
    if (arg.startsWith(argName))
    {
        if (arg.length == argName.length)
        {
            writefln("Error: option '%s' requires '=<value>'", argName);
            exit(1);
        }
        if (arg[argName.length] != '=')
            return null; // not the right option

        auto value = arg[argName.length + 1 .. $];
        if (!canBeEmpty && value.length == 0)
        {
            writefln("Error: empty command-line argument value %s", arg);
            exit(1);
        }
        return value;
    }
    return null;
}

int main(string[] args)
{
    args = args[1..$];

    // RDMD_FIX: the currrent shebang logic in rdmd seems flawed
    // handle the shebang operator
    if (args.length > 0)
    {
        size_t shebangLength = 0;
        enum shebangPrefix = "--shebang";
        if (args[0].startsWith(shebangPrefix)) {
            auto shebangArgs = args[0][shebangPrefix.length .. $];
            if (shebangArgs.startsWith("=")) {
                shebangArgs = shebangArgs[1 .. $];
            }
            args = std.string.split(shebangArgs) ~ args[2 .. $];
        }
    }

    string[] compilerArgsFromCommandLine;
    string mainSource;
    string[] runArgs;
    string compiler;
    bool buildOnly;
    bool force;
    bool help;
    RundSpecificCompilerOptions userOptions;

    {
        size_t compilerArgsLength = 0;
        void addCompilerArg(string arg)
        {
            arg = userOptions.handleCompilerArg(arg);
            if (arg)
                args[compilerArgsLength++] = arg;
        }

        scope(exit) compilerArgsFromCommandLine = args[0 .. compilerArgsLength];
        for (size_t i = 0; i < args.length; i++)
        {
            auto arg = args[i];
            if (!arg.startsWith("-"))
            {
                if (arg.endsWith(".d"))
                {
		    mainSource = arg;
		    runArgs = args[i + 1 .. $];
                    break;
                }
                addCompilerArg(arg);
            }
            else if (auto compilerValue = arg.isValueArg("--compiler", No.canBeEmpty))
            {
                compiler = which(compilerValue);
                if (compiler is null)
                {
                    writefln("Error: compiler '%s' was not found in PATH", compilerValue);
                    return 1;
                }
/*
                // TODO: check if the compiler has an older version of 'rund' installed
                //       alongside it.  If this is the case, could stop executing and
                //       call that version of rund which will have the correct interface
                //       to the corresponding compiler.
        auto compilerDir = dirName(compiler);
        auto thisExeDir = dirName(thisExePath());
        if (0 != filenameCmp(compilerDir, thisExeDir))
        {
            auto otherRund = buildPath(compilerDir, "rund" ~ binExt);
            if (otherRund.exists && otherRund.isFile)
            {
                yapf("forwarding call to '%s'", otherRund);
                auto process = spawnProcess(otherRund ~ args[1..$]);
                return process.wait();
            }
        }
    */
            }
            else if (auto cacheDir = arg.isValueArg("--cache", No.canBeEmpty))
            {
                cacheDirOverride = cacheDir;
            }
            else if (auto compilerArg = arg.isValueArg("--pass", No.canBeEmpty))
            {
                if (!compilerArg.endsWith(".d"))
                {
                    writefln("Error: invalid option '%s', value must end with '.d'", arg);
                    return 1;
                }
                addCompilerArg(compilerArg);
            }
            else if (arg == "--chatty")
                chatty = true;
            else if (arg == "--build-only")
                buildOnly = true;
            else if (arg == "--dry-run")
            {
                dryRun = true;
                chatty = true; // --dry-run implies --chatty
            }
            else if (arg == "--force")
                force = true;
            else if (arg == "--help" || arg == "-h")
                help = true;
            else
            {
                addCompilerArg(arg);
            }
        }
    }

    if (!mainSource || help)
    {
        usage();
        return 1;
    }

    if (!compiler)
    {
        // Look for the D compiler in the same directory as rund
        // and fall back to using the one in your path otherwise.
        auto compilerInSameDir = buildPath(dirName(thisExePath()), defaultCompiler);
        if (Chatty.existsAsFile(compilerInSameDir))
        {
            compiler = compilerInSameDir;
            yap("found compiler in same directory as rund: ", compiler);
        }
        else
        {
            compiler = Chatty.which(defaultCompiler);
            if (compiler is null)
            {
                writefln("Error: compiler '%s' was not found in PATH", defaultCompiler);
                return 1;
            }
            //compiler = defaultCompiler;
        }
    }

    // Get extra compiler arguments from mainSource
    string[] allCompilerArgs;

    {
        auto builder = appender!(string[])();
        try
        {
            processDirectivesFromFile(builder, mainSource);
        }
        catch (SourceDirectiveException e)
        {
            writefln("rund: Error: %s(%s): %s", e.file, e.line, e.msg);
            return 1; // fail
        }
        if (builder.data.length == 0)
            allCompilerArgs = compilerArgsFromCommandLine;
        else
        {
            yapf("got %s argument(s) from compiler directives in source:", builder.data.length);
            {
                size_t newLength = 0;
                scope(exit) builder.shrinkTo(newLength);
                for (size_t i = 0; i < builder.data.length; i++)
                {
                    auto arg = builder.data[i];
                    yap("  ", arg);
                    auto processed = userOptions.handleCompilerArg(arg);
                    if (processed)
                    {
                        builder.data[newLength++] = processed;
                    }
                }
            }
            allCompilerArgs = compilerArgsFromCommandLine ~ builder.data;
        }
    }

/+
    // start the web browser on documentation page
    void man()
    {
        std.process.browse("http://dlang.org/rund.html");
    }

    /* Only -of is supported because Make is very susceptible to file names, and
     * it doesn't do a good job resolving them. One option would be to use
     * std.path.buildNormalizedPath(), but some corner cases will break, so it
     * has been decided to only allow -of for now.
     * To see the full discussion please refer to:
     * https://github.com/dlang/tools/pull/122
     */
    if ((makeDepend || makeDepFile.ptr) && (!exe.ptr || exe.endsWith(dirSeparator)))
    {
        stderr.write(helpString);
        stderr.writeln();
        stderr.writeln("Missing option: --makedepend and --makedepfile need -of");
        return 1;
    }

    if (preserveOutputPaths)
    {
        argsBeforeProgram = argsBeforeProgram[0] ~ ["-op"] ~ argsBeforeProgram[1 .. $];
    }
+/

/+
    string[] programArgs;
    // Just evaluate this program!
    enforce(!(loop.ptr && eval.ptr), "Cannot mix --eval and --loop.");
    if (loop.ptr)
    {
        enforce(programPos == args.length, "Cannot have both --loop and a " ~
                "program file ('" ~ args[programPos] ~ "').");
        root = makeEvalFile(importWorld ~ "void main(char[][] args) { "
                ~ "foreach (line; std.stdio.stdin.byLine()) {\n"
                ~ std.string.join(loop, "\n")
                ~ ";\n} }");
        argsBeforeProgram ~= "-d";
    }
    else if (eval.ptr)
    {
        enforce(programPos == args.length, "Cannot have both --eval and a " ~
                "program file ('" ~ args[programPos] ~ "').");
        root = makeEvalFile(importWorld ~ "void main(char[][] args) {\n"
                ~ std.string.join(eval, "\n") ~ ";\n}");
        argsBeforeProgram ~= "-d";
    }
    else if (programPos < args.length)
    {
        root = args[programPos].chomp(".d") ~ ".d";
        programArgs = args[programPos + 1 .. $];
    }
    else // no code to run
    {
        write(helpString);
        return 1;
    }
+/

    // Compute the object directory and ensure it exists
    // NOTE: only use compiler arguments from the command line (don't include arguments
    //       pulled from main source "compiler directives". This is because those arguments
    //       are already covered by the timestamp of the main source file.
    immutable cacheDir = buildCachePath(compiler, mainSource, compilerArgsFromCommandLine);
    auto output = determineOutput(cacheDir, userOptions, mainSource);
    if (output.buildWitness)
        yapf("build witness %s", output.buildWitness.formatQuotedIfSpaces);
    else
        yap("build witness <NONE>");
    yapf("target binary %s", output.file.formatQuotedIfSpaces);

    //lockWorkPath(cacheDir); // will be released by the OS on process exit
    string objDir = buildPath(cacheDir, "objs");
    Chatty.mkdirRecurseIfLive(objDir);

    /+
    if (lib)
    {
        // When using -lib, the behavior of the DMD -of switch
        // changes: instead of being relative to the current
        // directory, it becomes relative to the output directory.
        // When building libraries, DMD does not generate any object
        // files; thus, we can override objDir (which is normally a
        // temporary directory) to be the current directory, so that
        // the relative -of path becomes correct.
        objDir = ".";
    }
    +/
    auto jsonFilename = buildPath(cacheDir, "lastBuild.json");
    if (determineCompile(force, output, jsonFilename, objDir))
    {
        immutable result = performBuild(compiler, mainSource, output.file, cacheDir, objDir,
            allCompilerArgs, jsonFilename);
        if (result)
            return result;
        if (output.buildWitness)
            Chatty.writeEmptyFile(output.buildWitness);
    }

    if (buildOnly || userOptions.noLink || userOptions.lib)
    {
        return 0;
    }

    // release lock on cacheDir before launching the user's program
    //unlockWorkPath();

    if (dryRun) return 0;
    auto runCommand = output.file ~ runArgs;
    version (Windows)
    {
        // Windows doesn't have exec, fall back to spawnProcess then wait
        auto pid = spawnProcess(runCommand);
        return pid.wait();
    }
    else
    {
        import std.process : execv;
        auto argv = runCommand.map!toStringz.chain(null.only).array;
        return execv(argv[0], argv.ptr);
    }
}

struct Output
{
    string file;
    /*
    The `buildWitness` is a file that holds the timestamp that the target was last built
    this is useful if the executable is built somewhere else other than
    the cache directory.

    We need to be careful about using -o. Normally the generated
    executable is hidden in the unique directory cacheDir. But if the
    user forces generation in a specific place by using -od or -of,
    the time of the binary can't be used to check for freshness
    because the user may change e.g. the compile option from one run
    to the next, yet the generated binary's datetime stays the
    same. In those cases, we'll use a dedicated file called ".built"
    and placed in cacheDir. Upon a successful build, ".built" will be
    touched. See also
    http://d.puremagic.com/issues/show_bug.cgi?id=4814

    TODO: make sure there is a test for this
    */
    string buildWitness;
}
Output determineOutput(string cacheDir, RundSpecificCompilerOptions userOptions, string mainSource)
{
    string outExt;
    if (userOptions.lib)
        outExt = libExt;
    else if (userOptions.noLink)
        outExt = objExt;
    else
        outExt = binExt;

    const mainSourceDir = mainSource.dirName;
    const mainSourceBaseName = mainSource.baseName(".d");
    string outputFile;
    bool useBuildWitness;

    if (userOptions.outputDir)
    {
        useBuildWitness = true;
        if (userOptions.outputFileOption)
        {
            outputFile = buildPath(userOptions.outputDir,
                userOptions.outputFileOption.defaultExtension(outExt));
        }
        else
        {
            outputFile = buildPath(userOptions.outputDir, mainSourceBaseName ~ outExt);
        }
    }
    else if (userOptions.outputFileOption)
    {
        useBuildWitness = true;
        outputFile = userOptions.outputFileOption.defaultExtension(outExt);
    }
    else
    {
        useBuildWitness = false;
        outputFile = buildPath(cacheDir, mainSourceBaseName ~ outExt);
    }

    return Output(outputFile, useBuildWitness ? buildPath(cacheDir, "buildWitness") : null);
}

Flag!"compile" determineCompile(bool force, Output output, string jsonFilename, string objDir)
{
    if (force)
    {
        yap("COMPILE(YES) --force was given");
        return Yes.compile;
    }

    SysTime lastBuildTime = Chatty.timeLastModified(output.file, SysTime.min);
    if (lastBuildTime == SysTime.min)
    {
        yapf("COMPILE(YES) ouptut file %s does not exist", output.file.formatQuotedIfSpaces);
        return Yes.compile;
    }
    if (output.buildWitness)
    {
        auto buildWitnessTime = Chatty.timeLastModified(output.buildWitness, SysTime.min);
        if (lastBuildTime == SysTime.min)
        {
            yapf("COMPILE(YES) build witness %s does not exist", output.buildWitness.formatQuotedIfSpaces);
            return Yes.compile;
        }
        // If output.file is newer than output.buildWitness, then that means that the output file has been changed/overwritten.
        // This means a rebuild is needed.  A common use case for this is if rund is called multiple times with different
        // arguments but with the same output file name.
        if (lastBuildTime > buildWitnessTime)
        {
            yapf("COMPILE(YES) build witness %s is older than output file", output.buildWitness.formatQuotedIfSpaces);
            return Yes.compile;
        }
        lastBuildTime = buildWitnessTime;
    }

    auto jsonFileModifyTime = Chatty.timeLastModified(jsonFilename, SysTime.min);
    if (jsonFileModifyTime == SysTime.min)
    {
        yapf("COMPILE(YES) json file %s does not exist", jsonFilename.formatQuotedIfSpaces);
        return Yes.compile;
    }
    // TODO: what happens if json modify time is different from outputFileTime and/or build witness time?
    auto deps = readJsonFile(jsonFilename, objDir);

    auto updated = deps.byKey.anyNewerThan(lastBuildTime);
    if (updated)
    {
        yapf("COMPILE(YES) updated file '%s'", updated.formatQuotedIfSpaces);
        return Yes.compile;
    }

    yap("COMPILE(NO)");
    return No.compile;
}

// NOTE:
// this must be an absolute directory because
// it is used to pass -od= and -of= to the compiler, and if it
// it not absolute then -of= will be interpreted as relative to -od=
// which would be incorrect
private string buildDefaultCacheDir()
out(result) { assert(isAbsolute(result)); } do
{
    auto cacheRoot = tempDir();
    version (Posix)
    {
        import core.sys.posix.unistd : getuid;
        // TODO: not sure why each user gets their own cache directory.
        //       this seems unnecessary
        return buildPath(cacheRoot, ".rund-%d".format(getuid()));
    }
    else
    {
        return cacheRoot.replace("/", dirSeparator).buildPath(".rund");
    }
}

private string rundCacheDir()
{
    static string cachedRundCacheDir;
    if (!cachedRundCacheDir)
    {
        string cacheRoot;
        if (cacheDirOverride)
            cacheRoot = cacheDirOverride;
        else
            cacheRoot = buildDefaultCacheDir();

        Chatty.mkdirRecurseIfLive(cacheRoot);
        cachedRundCacheDir = cacheRoot;
    }
    return cachedRundCacheDir;
}

private string buildCachePath(in string compiler, in string mainSource, in string[] compilerArgs)
{
    enum string[] irrelevantSwitches = [
        "--help", "-ignore", "-quiet", "-v" ];

    MD5 context;
    context.start();
    yapf("[DEBUG] CACHE_PATH ADD '%s'", compiler);
    context.put(compiler.representation);
    auto mainSourceAbsoluteNormalized = mainSource.absolutePath.buildNormalizedPath;
    yapf("[DEBUG] CACHE_PATH ADD '%s'", mainSourceAbsoluteNormalized);
    context.put(mainSourceAbsoluteNormalized.representation);
    foreach (flag; compilerArgs)
    {
        if (!irrelevantSwitches.canFind(flag))
        {
            yapf("[DEBUG] CACHE_PATH ADD '%s'", flag);
            context.put(flag.representation);
        }
    }
    auto digest = context.finish();
    auto hashOfCompilerArgs = toHexString(digest);

    const tmpRoot = rundCacheDir();
    auto cachePath = buildPath(tmpRoot, "rund-" ~ baseName(mainSource) ~ '-' ~ hashOfCompilerArgs);
    Chatty.mkdirRecurseIfLive(cachePath);
    return cachePath;
}

/+
private File lockFile;

private void lockWorkPath(string workPath)
{
    string lockFileName = buildPath(workPath, "rund.lock");
    if (!dryRun) lockFile.open(lockFileName, "w");
    yap("lock ", lockFile.name);
    if (!dryRun) lockFile.lock();
}

private void unlockWorkPath()
{
    yap("unlock ", lockFile.name);
    if (!dryRun)
    {
        lockFile.unlock();
        lockFile.close();
    }
}
+/

private int performBuild(in string compiler, string mainSource, string outputFile,
    string cacheDir, string objDir, string[] compilerArgs, string jsonFilename)
{
    // Delete the old executable before we start building.
    {
        auto attrs = Chatty.getFileAttributes(outputFile);
        if (attrs.exists)
        {
            enforce(attrs.isFile, "cannot remove '" ~ outputFile ~ "' because is not a normal file");
            try
                Chatty.removeIfLive(outputFile);
            catch (FileException e)
            {
                // This can occur on Windows if the executable is locked.
                // Although we can't delete the file, we can still rename it.
                yap("failed to remove %s: %s, attempting to rename it instead",
                    outputFile, e.msg);
                auto oldExe = "%s.%s-%s.old".format(outputFile,
                    Clock.currTime.stdTime, thisProcessID);
                Chatty.rename(outputFile, oldExe);
            }
        }
    }

    auto outputFileTemp = buildPath(cacheDir, "compilerOutput.tmp");

    auto allCompilerArgs = compilerArgs ~ [
        "-of=" ~ outputFileTemp,
        "-od=" ~ objDir,
        "-I=" ~ dirName(mainSource),
        "-i",
        "-Xf=" ~ jsonFilename,
        "-Xi=compilerInfo",
        "-Xi=buildInfo",
        "-Xi=semantics",
        mainSource
    ];

    //
    // !!! ALWAYS USE A RESPONSE FILE RIGHT NOW !!!
    //
    // Different shells and OS functions have different limits,
    // but 1024 seems to be the smallest maximum outside of MS-DOS.
    //enum maxLength = 1024;
    //auto fullCommand = escapeShellCommand([compiler] ~ extraCompilerArgs);
    //if (fullCommand.length >= maxLength)

    // DMD uses Windows-style command-line parsing in response files
    // regardless of the operating system it's running on.
    auto responseFile = buildPath(cacheDir, "rund.rsp");
    Chatty.write(responseFile, array(map!escapeWindowsArgument(allCompilerArgs)).join(" "));
    auto spawnArgs = [compiler, "@" ~ responseFile];

    void printCompilerShellCommand(File file)
    {
        file.writeln("[COMPILER_SHELL_COMMAND] ", escapeShellCommand([compiler] ~ allCompilerArgs));
    }

    // Print a form of the compiler command that can be copy/pasted
    // to a shell to be run again
    if (chatty)
        printCompilerShellCommand(stdout);
    if (dryRun)
        return 0;

    if (chatty)
        writeln("[SPAWN] ", escapeShellCommand(spawnArgs));
    auto process = spawnProcess(spawnArgs);
    int exitCode = process.wait();
    if (exitCode)
    {
        stderr.writeln("--------------------------------------------------------------------------------");
        stderr.writefln("rund: Error: compilation failed (exit code %s)", exitCode);
        // print the compiler command if it wasn't already printed via chatty
        if (!chatty)
            printCompilerShellCommand(stderr);
        if (Chatty.exists(outputFileTemp))
            Chatty.remove(outputFileTemp);
        if (Chatty.exists(jsonFilename))
            Chatty.remove(jsonFilename);
    }
    else
    {
        // NOTE: using `rename` has problems when moving files between
        //       filesystems/drives, for that reason, I created `moveFile`
        //       which falls back to copy/remove
        Chatty.moveFile(outputFileTemp, outputFile);
    }
    /*
    if (jsonSettings.enabled)
    {
        string targetJsonFile;
        if (jsonSettings.filename)
            targetJsonFile = jsonSettings.filename;
        else
            targetJsonFile = root.baseName.chomp(".d") ~ ".json";
        if (jsonFilename != targetJsonFile)
            Chatty.copy(jsonFilename, targetJsonFile);
    }
    */

    // clean up the dir containing the object file
    if (Chatty.exists(objDir) && objDir.startsWith(cacheDir))
    {
        // We swallow the exception because of a potential race: two
        // concurrently-running scripts may attempt to remove this
        // directory. One will fail.
        collectException(Chatty.rmdirRecurse(objDir));
    }
    return exitCode;
}

/**
Compiler options that rund uses when invoking the compiler.
These are the options that rund needs to know about when they
are specified by the user.
*/
struct RundSpecificCompilerOptions
{
    bool noLink;
    bool lib;
    string outputFileOption;
    string outputDir;
    bool preserveOutputPaths;
    bool jsonOutputEnabled;
    string jsonFilename;
    string[] jsonInclude;

    // returns the argument modified, null to remove it
    string handleCompilerArg(string arg)
    {
        auto originalArg = arg;

        if (arg == "-c")
            this.noLink = true;
        else if (arg == "-lib")
            this.lib = true;
        else if (arg.skipOver("-o"))
        {
            if (arg.skipOver('f'))
            {
                arg.skipOver('='); // support -of and -of=
                this.outputFileOption = arg;
                return null; // remove this argument
            }
            else if (arg.skipOver('d'))
            {
                // -odmydir passed
                arg.skipOver('='); // support -od and -od=
                this.outputDir = arg;
                return null;
            }
            else if (arg == "-")
            {
                // -o- passed
                enforce(false, "Option -o- currently not supported by rund");
            }
            else if (arg == "p")
            {
                // -op passed
                this.preserveOutputPaths = true;
            }
            else
                enforce(false, "Unrecognized option: " ~ originalArg);
        }
        else if (arg.skipOver("-X"))
        {
            this.jsonOutputEnabled = true;
            if (arg.skipOver('f'))
            {
                arg.skipOver('=');
                this.jsonFilename = arg;
                return null; // remove this argument
            }
            else if (arg.skipOver('i'))
            {
                arg.skipOver('=');
                this.jsonInclude ~= arg;
                // todo: only remove if recognized
                return null; // remove this argument
            }
            else
                enforce(false, "Unrecognized option: " ~ originalArg);
        }
        else if (arg == "-i")
        {
            return null; // remove this, since rund will adding this argument anyway
        }
        return originalArg; // keep the argument as is
    }
}

inout(char)[] defaultExtension(inout(char)[] path, const(char)[] ext)
{
    if (ext.length == 0)
        return path;

    assert(ext[0] == '.');
    auto dotIndex = path.lastIndexOf('.');
    if (dotIndex < 0)
        return cast(inout(char)[])(path ~ ext);
    return path;
}
