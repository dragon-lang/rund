#!/usr/bin/env rund
//!importPath src
//!debug
//!debugSymbols

// TODO: replace assert with enforce

module rund_test;

import core.thread : Thread;
import core.time : dur;

import std.algorithm;
import std.exception;
import std.file;
import std.getopt;
import std.path;
import std.process;
import std.range;
import std.string;
import std.stdio;

import rund.common;
import rund.file;
import rund.compiler;

__gshared string rundTempDir;

class SilentException : Exception { this() { super(null); } }

int main(string[] args)
{
    try { return tryMain(args); }
    catch(SilentException) { return 1; }
}
int tryMain(string[] args)
{
    bool concurrencyTest;
    version(Windows)
    {
        string model = null;
    }
    else
    {
        string model = "64";
    }
    string testCompilerList; // e.g. "ldmd2,gdmd" (comma-separated list of compiler names)

    auto helpInfo = getopt(args,
        "concurrency", "whether to perform the concurrency test cases", &concurrencyTest,
        "m|model", "architecture to run the tests for [32 or 64]", &model,
        "test-compilers", "comma-separated list of D compilers to test with rund", &testCompilerList,
    );

    void reportHelp(string errorMsg = null, string file = __FILE__, size_t line = __LINE__)
    {
        defaultGetoptPrinter("rund_test: a test suite for rund\n\n" ~
                             "USAGE:\trund_test [OPTIONS] <rund_binary>\n",
                             helpInfo.options);
        enforce(errorMsg is null, errorMsg, file, line);
    }

    if (helpInfo.helpWanted || args.length == 1)
    {
        reportHelp();
        return 1;
    }

    if (args.length > 2)
    {
        errorf("too many non-option arguments, expected 1 but got %s", args.length - 1);
        return 1; // fail
    }
    string rund = args[1]; // path to rund executable

    if (rund.length == 0)
        reportHelp("ERROR: missing required --rund flag");

    enforce(rund.exists,
            format("rund executable path '%s' does not exist", rund));

    // copy rund executable to temp dir: this enables us to set
    // up its execution environment with other features, e.g. a
    // dummy fallback compiler
    rundTempDir = buildPath(tempDir(), "rund_test");
    if (exists(rundTempDir))
        rmdirRecurse(rundTempDir);
    mkdir(rundTempDir);
    const rundApp = buildPath(rundTempDir, "rund_app_" ~ binExt);
    // don't remove rundApp on failure so that the user can
    // execute it
    scope (success) std.file.remove(rundApp);
    copy(rund, rundApp, Yes.preserveAttributes);

    const helloExe = buildPath(rundTempDir, "helloWorld" ~ binExt);
    execPass([rundApp].addModelSwitch(model) ~ ["--build-only", "-of=" ~ helloExe,
        buildPath(__FILE_FULL_PATH__.dirName, "test", "helloWorld.d")]);
    const dummyCompiler = buildPath(rundTempDir, "dummycompiler" ~ binExt);
    execPass([rundApp].addModelSwitch(model) ~ ["--build-only", "-of=" ~ dummyCompiler,
        buildPath(__FILE_FULL_PATH__.dirName, "test", "dummycompiler.d")]);

    runCompilerAgnosticTests(rundApp, model, dummyCompiler);

    if (testCompilerList is null)
    {
        testCompilerList = tryFindDCompilerInPath();
        if (testCompilerList is null)
        {
            errorf("cannot find a D compiler");
            return 1;
        }
    }

    // run the test suite for each specified test compiler
    foreach (testCompiler; testCompilerList.split(','))
    {
        // if compiler is a relative filename it must be converted
        // to absolute because this test changes directories
        if (testCompiler.canFind!isDirSeparator || testCompiler.exists)
            testCompiler = buildNormalizedPath(testCompiler.absolutePath);

        runTests(rundApp, testCompiler, model);
        if (concurrencyTest)
            runConcurrencyTest(rundApp, testCompiler, model);
    }

    return 0;
}

void logf(T...)(const(char)[] fmt, T args)
{
    write("[rund_test] ");
    writefln(fmt, args);
}
void errorf(T...)(const(char)[] fmt, T args)
{
    write("[rund_test] Error: ");
    writefln(fmt, args);
}
void rmdirRecurse(scope const(char)[] dir)
{
    logf("rmRecurse '%s'", dir);
    std.file.rmdirRecurse(dir);
}
void chdir(R)(R pathname)
{
    logf("cd '%s'", pathname);
    std.file.chdir(pathname);
}

auto addModelSwitch(string[] args, string model)
{
    if (model.length > 0)
    {
        args = args ~ ["-m" ~ model];
    }
    return args;
}

string envShellPrefix(const string[string] env)
{
    string result = "";
    foreach (pair; env.byKeyValue)
    {
        result ~= pair.key ~ "=" ~ pair.value ~ " ";
    }
    return result;
}
auto execute(scope const(char[])[] args, const string[string] env = null)
{
    logf("[execute] %s%s", envShellPrefix(env), escapeShellCommand(args));
    return std.process.execute(args, env);
}

void enforceCanFind(const(char)[] text, const(char)[] expected)
{
    if (!text.canFind(expected))
    {
        writeln("------------------------------------------");
        errorf("the following text did not contain '%s'", expected);
        writeln("------------------------------------------");
        writeln(text);
        writeln("------------------------------------------");
        throw new SilentException();
    }
}
void enforceCannotFind(const(char)[] text, const(char)[] expected)
{
    if (text.canFind(expected))
    {
        writeln("------------------------------------------");
        errorf("the following text SHOULD NOT contain '%s'", expected);
        writeln("------------------------------------------");
        writeln(text);
        writeln("------------------------------------------");
        throw new SilentException();
    }
}

auto execPass(scope const(char[])[] args, const string[string] env = null)
{
    const res = execute(args, env);
    if (res.status != 0)
    {
        errorf("the last command failed with exit code %s and with the following output:", res.status);
        writeln("-----------------------------------------------------------");
        writeln(res.output);
        writeln("-----------------------------------------------------------");
        throw new SilentException();
    }
    return res.output;
}
auto execFail(scope const(char[])[] args, const string[string] env = null)
{
    const res = execute(args, env);
    if (res.status == 0)
    {
        errorf("the last command should have failed but it passed with the following output:");
        writeln("-----------------------------------------------------------");
        writeln(res.output);
        writeln("-----------------------------------------------------------");
        throw new SilentException();
    }
    return res.output;
}

void enforce(T...)(bool condition, lazy const(char)[] fmt, lazy T args)
{
    if (!condition)
    {
        errorf(fmt, args);
        throw new SilentException();
    }
}
auto enforceExists(inout(char)[] file)
{
    enforce(exists(file), "file '%s' does not exist", file);
    return file;
}
auto enforcedRemove(inout(char)[] file)
{
    remove(file);
    enforce(!exists(file), "failed to remove file '%s'", file);
    return file;
}

void runCompilerAgnosticTests(string rundApp, string model, string dummyCompiler)
{
    // Test help string output when no arguments passed.
    execFail([rundApp])
        .enforceCanFind("Usage: rund [rund/compiler options]... program.d [program options]...");

    // Test --help
    string helpText;
    {
        auto res = execute([rundApp, "--help"]);
        assert(res.status == 1, res.output);
        assert(res.output.canFind("Usage: rund [rund/compiler options]... program.d [program options]..."));
        helpText = res.output;
    }

    // Test that unsupported -o... options result in failure
    execFail([rundApp, "-o-"])  // valid option for dmd but unsupported by rund
        .enforceCanFind("Option -o- currently not supported by rund");

    execFail([rundApp, "-o-foo"]) // should not be treated the same as -o-
        .enforceCanFind("Unrecognized option: -o-foo");

    execFail([rundApp, "-opbreak"]) // should not be treated like valid -op
        .enforceCanFind("Unrecognized option: -opbreak");

    // check that rund can find all compilers
    const rundArgsNoCompiler = rundArguments(rundApp, null, model);
    {
        auto tempBinDir = buildPath(rundTempDir, "tempbin");
        mkdir(tempBinDir);
        const tempFile = makeTempFile(buildPath(rundTempDir, "temp.d"), ``);
        foreach (name; DCompilers)
        {
            runFallbackTest(rundApp, name, model);
            const link = buildPath(tempBinDir, name);
            version (Posix)
                symlink(dummyCompiler, link);
            else
                copy(dummyCompiler, link);
            execPass(rundArgsNoCompiler ~ [tempFile], [ "PATH": tempBinDir ])
                .enforceCanFind("Running in dummy exe mode");
            remove(link);
        }
        remove(tempFile);
    }
}

auto rundArguments(string rundApp, string compiler, string model)
{
    auto args = [rundApp];
    if (compiler)
        args ~= ["--compiler=" ~ compiler];
    if (model)
        args = args.addModelSwitch(model);
    return args;
}

auto makeTempFile(string name, string contents)
{
    auto filename = buildPath(rundTempDir, name);
    std.file.write(filename, contents);
    return filename;
}

auto makeFileWithRetry(string filename, string contents)
{
    // windows can have problems if you overwrite a file too fast, such
    // as an executable file that was just running in a process
    version (Windows)
    {
        import core.sys.windows.winerror : ERROR_SHARING_VIOLATION;
        for (uint attempt = 1; ; attempt++)
        {
            try
            {
                std.file.write(filename, contents);
                break;
            }
            catch(FileException e)
            {
                if (attempt < 4 && e.errno == ERROR_SHARING_VIOLATION)
                {
                    logf("caught FileException ERROR_SHARING_VIOLATION when creating '%s'...trying again", filename);
                    continue;
                }
                throw e;
            }
        }
    }
    else
    {
        std.file.write(filename, contents);
    }
    return filename;
}

/*
On my box I had cases where creating a file would not have a newer
timestamp than the output files they were checked against.  This function
will create a file and make sure that it has a newer timestamp than whatever
the time currently is.

An example where this is used is when we modify the output file to make it
newer than the buildWitness.  I was getting cases where I'd modify the output file
but it would have the SAME timestamp as the builtWitness...it was just going too fast!
*/
auto makeFileNewerThanNow(string filename, string contents)
{
    // first get the current time by creating the file empty and getting it's modify time
    makeFileWithRetry(filename, "");
    const now = timeLastModified(filename);

    for (;;)
    {
        makeFileWithRetry(filename, contents);
        const newTime = timeLastModified(filename);
        if (newTime > now)
            break;
        logf("Timestamp of '%s' (%s) not updated. Creating again...", filename, now);
        Thread.sleep(dur!"msecs"(1));
    }
}


enum CompilingSourceMessage = "compiling source";
enum PragmaPrintSource = `void main() { pragma(msg, "` ~ CompilingSourceMessage ~ `"); }`;

struct TestFiles
{
    string pragmaPrintCompilingSource;
    string voidMain;
    string failComptime;
    string failRuntime;
    string hello;
    void create()
    {
        pragmaPrintCompilingSource = makeTempFile("pragma_print.d", PragmaPrintSource);
        voidMain = makeTempFile("void_main_.d", "void main() { }");
        failComptime = makeTempFile("fail_comptime_.d",
            "void main() { static assert(0); }");
        failRuntime = makeTempFile("fail_runtime_.d",
            "void main() { assert(0); }");
        hello = makeTempFile("hello.d", "import std.stdio; void main() { writeln(\"Hello!\"); }");
    }
}

void runTests(string rundApp, string compiler, string model)
{
    // path to rund + common arguments (compiler, model)
    const rundArgs = rundArguments(rundApp, compiler, model);

    auto testFiles = TestFiles();
    testFiles.create();

    execPass(rundArgs ~ [testFiles.hello])
        .enforceCanFind("Hello!");
    execPass(rundArgs ~ [testFiles.hello.stripExtension])
        .enforceCanFind("Hello!");

    // Test --force
    execPass(rundArgs ~ [testFiles.pragmaPrintCompilingSource])
        .enforceCanFind(CompilingSourceMessage);
    execPass(rundArgs ~ [testFiles.pragmaPrintCompilingSource])
        .enforceCannotFind(CompilingSourceMessage);  // second call will not re-compile
    execPass(rundArgs ~ ["--force", testFiles.pragmaPrintCompilingSource])
        .enforceCanFind(CompilingSourceMessage);  // force will re-compile

    // Test works with -main.  This is a corner case since dmd will add the file '__main.d'
    // but it doesn't exist afterwards, so rund needs to handle that file specially.
    {
        auto pragmaCompilingNoMain = makeTempFile("pragma_print_nomain.d", `pragma(msg, "` ~ CompilingSourceMessage ~ `");`);
        scope (success) remove(pragmaCompilingNoMain);
        execPass(rundArgs ~ ["-main", pragmaCompilingNoMain])
            .enforceCanFind(CompilingSourceMessage);
        execPass(rundArgs ~ ["-main", pragmaCompilingNoMain])
            .enforceCannotFind(CompilingSourceMessage);  // second call will not re-compile
        execPass(rundArgs ~ ["-main", "--force", pragmaCompilingNoMain])
            .enforceCanFind(CompilingSourceMessage);  // force will re-compile
    }

    // Test works when compiling a std library module
    {
        auto pragmaCompilingNoMain = makeTempFile("pragma_print_nomain.d", `module std.foo;pragma(msg, "` ~ CompilingSourceMessage ~ `");`);
        scope (success) remove(pragmaCompilingNoMain);
        execPass(rundArgs ~ ["-main", pragmaCompilingNoMain])
            .enforceCanFind(CompilingSourceMessage);
        execPass(rundArgs ~ ["-main", pragmaCompilingNoMain])
            .enforceCannotFind(CompilingSourceMessage);  // second call will not re-compile
        {
            auto file = File(pragmaCompilingNoMain, "a");
            file.write("\n// just adding something to force a recompile");
            file.close();
        }
        execPass(rundArgs ~ ["-main", pragmaCompilingNoMain])
            .enforceCanFind(CompilingSourceMessage);
    }

    // Test --build-only
    execPass(rundArgs ~ ["--force", "--build-only", testFiles.failRuntime]);
    execFail(rundArgs ~ ["--force", testFiles.failRuntime]);

    execFail(rundArgs ~ ["--force", "--build-only", testFiles.failComptime]);
    execFail(rundArgs ~ ["--force", testFiles.failComptime]);

    // Test --chatty
    execPass(rundArgs ~ ["--force", "--chatty", testFiles.voidMain])
        // TODO: enforceCanFind exists tempDir()/void_main_
        .enforceCanFind("exists ");

    // Test --dry-run
    // static assert(0) not called since we did not build.
    execPass(rundArgs ~ ["--force", "--dry-run", testFiles.failComptime])
        .enforceCanFind("mkdirRecurse ");  // --dry-run implies chatty

    // --build-only should not interfere with --dry-run
    execPass(rundArgs ~ ["--force", "--dry-run", "--build-only", testFiles.failComptime]);

    /+
    TODO: haven't implemented --eval yet

    // Test --eval
    auto res = execute(rundArgs ~ ["--force", "-de", "--eval=writeln(`eval_works`);"]);
    assert(res.status == 0, res.output);
    res.output.enforceCanFind("eval_works");  // there could be a "DMD v2.xxx header in the output"

    // compiler flags
    res = execute(rundArgs ~ ["--force", "-debug",
        "--eval=debug {} else assert(false);"]);
    assert(res.status == 0, res.output);

    // vs program file
    res = execute(rundArgs ~ ["--force",
        "--eval=assert(true);", testFiles.voidMain]);
    assert(res.status != 0);
    res.output.enforceCanFind("Cannot have both --eval and a program file ('" ~
            testFiles.voidMain ~ "').");
    +/

    // Test exclusion (-i=-<pattern>)
    string packFolder = buildPath(rundTempDir, "dsubpack");
    if (packFolder.exists) packFolder.rmdirRecurse();
    packFolder.mkdirRecurse();
    scope (success) packFolder.rmdirRecurse();

    string subModObj = packFolder.buildPath("submod") ~ objExt;
    string subModSrc = packFolder.buildPath("submod.d");
    std.file.write(subModSrc, "module dsubpack.submod; void foo() { }");

    // build an object file out of the dependency
    execPass(rundArgs ~ ["-c", "-of" ~ subModObj, subModSrc]);

    string subModUser = buildPath(rundTempDir, "subModUser_.d");
    std.file.write(subModUser, "module subModUser_; import dsubpack.submod; void main() { foo(); }");

    // building without the dependency fails
    execFail(rundArgs ~ ["--force", "-i=-dsubpack", subModUser]);

    // building with the dependency succeeds
    execPass(rundArgs ~ ["--force", "-i=-dsubpack", subModObj, subModUser]);

    // Test inclusion (-i=<pattern>)
    auto packFolder2 = buildPath(rundTempDir, "std");
    if (packFolder2.exists) packFolder2.rmdirRecurse();
    packFolder2.mkdirRecurse();
    scope (success) packFolder2.rmdirRecurse();

    string subModSrc2 = packFolder2.buildPath("foo.d");
    std.file.write(subModSrc2, "module std.foo; void foobar() { }");

    std.file.write(subModUser, "import std.foo; void main() { foobar(); }");

    // building without the -i=std fails
    execFail(rundArgs ~ ["--force", subModUser]);
    // building with the -i=std succeeds
    execPass(rundArgs ~ ["--force", "-i=std", subModUser]);

    // Test --pass=<file>
    {
        string extraFileDi = makeTempFile("extraFile_.di",
            "module extraFile_; void f();");
        string extraFileD = makeTempFile("extraFile_.d",
            "module extraFile_; void f() { return; }");
        string extraFileMain = makeTempFile("extraFileMain_.d",
            "module extraFileMain_; import extraFile_; void main() { f(); }");

        // undefined reference to f()
        execFail(rundArgs ~ ["--force", extraFileMain]);
        execPass(rundArgs ~ ["--force", "--pass=" ~ extraFileD, extraFileMain]);
    }

/+
    --loop not implemented, not sure how useful it is

/* Test --loop. */
    {
    auto testLines = "foo\nbar\ndoo".split("\n");

    auto pipes = pipeProcess(rundArgs ~ ["--force", "--loop=writeln(line);"], Redirect.stdin | Redirect.stdout);
    foreach (input; testLines)
        pipes.stdin.writeln(input);
    pipes.stdin.close();

    while (!testLines.empty)
    {
        auto line = pipes.stdout.readln.strip;
        if (line.empty || line.startsWith("DMD v")) continue;  // git-head header
        assert(line == testLines.front, "Expected %s, got %s".format(testLines.front, line));
        testLines.popFront;
    }
    auto status = pipes.pid.wait();
    assert(status == 0);
    }

    // vs program file
    res = execute(rundArgs ~ ["--force",
        "--loop=assert(true);", testFiles.voidMain]);
    assert(res.status != 0);
    res.output.enforceCanFind("Cannot have both --loop and a program file ('" ~
            testFiles.voidMain ~ "').");
    +/

    /+
    --makedepend/--makedepfile not implemented, not sure how useful they are
    maybe this functionality should be in another tool, a tool that takes the
    output of the JSON file and creates a dependency file

    /* Test --makedepend. */

    string packRoot = packFolder.buildPath("../").buildNormalizedPath();

    string depMod = packRoot.buildPath("depMod_.d");
    std.file.write(depMod, "module depMod_; import dsubpack.submod; void main() { }");

    res = execute(rundArgs ~ ["-I" ~ packRoot, "--makedepend",
            "-of" ~ depMod[0..$-2], depMod]);

    import std.ascii : newline;

    // simplistic checks
    res.output.enforceCanFind(depMod[0..$-2] ~ ": \\" ~ newline);
    res.output.enforceCanFind(newline ~ " " ~ depMod ~ " \\" ~ newline);
    res.output.enforceCanFind(newline ~ " " ~ subModSrc);
    res.output.enforceCanFind(newline ~  subModSrc ~ ":" ~ newline);
    res.output.enforceCannotFind("\\" ~ newline ~ newline);

    /* Test --makedepfile. */

    string depModFail = packRoot.buildPath("depModFail_.d");
    std.file.write(depModFail, "module depMod_; import dsubpack.submod; void main() { assert(0); }");

    string depMak = packRoot.buildPath("depMak_.mak");
    res = execute(rundArgs ~ ["--force", "--build-only",
            "-I" ~ packRoot, "--makedepfile=" ~ depMak,
            "-of" ~ depModFail[0..$-2], depModFail]);
    scope (exit) std.file.remove(depMak);

    string output = std.file.readText(depMak);

    // simplistic checks
    assert(output.canFind(depModFail[0..$-2] ~ ": \\" ~ newline));
    assert(output.canFind(newline ~ " " ~ depModFail ~ " \\" ~ newline));
    assert(output.canFind(newline ~ " " ~ subModSrc));
    assert(output.canFind(newline ~ "" ~ subModSrc ~ ":" ~ newline));
    assert(!output.canFind("\\" ~ newline ~ newline));
    assert(res.status == 0, res.output);  // only built, assert(0) not called.
+/

    // Test signal propagation through exit codes
    version (Posix)
    {{
        import core.sys.posix.signal;
        string crashSrc = makeTempFile("crash_src_.d",
            `void main() { int *p; *p = 0; }`);
        auto res = execute(rundArgs ~ [crashSrc]);
        assert(res.status == -SIGSEGV, format("%s", res));
    }}

    // -of doesn't append .exe on Windows: https://issues.dlang.org/show_bug.cgi?id=12149
    version (Windows)
    {{
        auto outPath = buildPath(rundTempDir, "test_of_app");
        auto outExe = outPath ~ ".exe";
        if (exists(outExe))
            remove(outExe);
        execPass([rundApp, "--build-only", "-of" ~ outPath, testFiles.voidMain]);
        outExe.enforceExists.enforcedRemove;
    }}

    // Current directory change should not trigger rebuild
    execPass(rundArgs ~ [testFiles.pragmaPrintCompilingSource])
        .enforceCannotFind(CompilingSourceMessage);

    {
        auto cwd = getcwd();
        chdir(rundTempDir);
        scope(exit) chdir(cwd);

        execPass(rundArgs ~ [testFiles.pragmaPrintCompilingSource.baseName])
            .enforceCannotFind(CompilingSourceMessage);
    }

    auto conflictDir = testFiles.pragmaPrintCompilingSource.setExtension(".dir");
    if (exists(conflictDir))
    {
        if (isFile(conflictDir))
            remove(conflictDir);
        else
            rmdirRecurse(conflictDir);
    }
    mkdir(conflictDir);
    // should fail because output file conflicts with directory
    execFail(rundArgs ~ ["-of" ~ conflictDir, testFiles.pragmaPrintCompilingSource]);
    execFail(rundArgs ~ ["-of=" ~ conflictDir, testFiles.pragmaPrintCompilingSource]);

    // rund should force rebuild when --compiler changes: https://issues.dlang.org/show_bug.cgi?id=15031

    execPass(rundArgs ~ [testFiles.pragmaPrintCompilingSource])
        .enforceCannotFind(CompilingSourceMessage);

    {
        auto fullCompilerPath = which(compiler);
        //assert(compiler != fullCompilerPath, "TODO: FIX TEST HERE");
        execPass([rundApp, "--compiler=" ~ fullCompilerPath, testFiles.pragmaPrintCompilingSource]);
    }

    // Create an empty temporary directory and clean it up when exiting scope
    static struct TempDir
    {
        string name;
        this(string name)
        {
            this.name = name;
            if (exists(name)) rmdirRecurse(name);
            mkdir(name);
        }
        @disable this(this);
        ~this()
        {
            version (Windows)
            {
                import core.thread;
                Thread.sleep(100.msecs); // Hack around Windows locking the directory
            }
            rmdirRecurse(name);
        }
        alias name this;
    }
    static string tempDirCode(string dirVarName)
    {
        return
        `if (exists(` ~ dirVarName ~ `)) rmdirRecurse(` ~ dirVarName ~ `);
        mkdir(` ~ dirVarName ~ `);
        // only remove on success
        scope(success)
        {
            version (Windows)
            {
                import core.thread;
                Thread.sleep(100.msecs); // Hack around Windows locking the directory
            }
            rmdirRecurse(` ~ dirVarName ~ `);
        }
`;
    }

    /* tempdir */
    {
        execPass(rundArgs ~ [testFiles.pragmaPrintCompilingSource, "--build-only"]);

        TempDir tempdir = "rundTest";
        execPass(rundArgs ~ ["--cache=" ~ tempdir, testFiles.pragmaPrintCompilingSource, "--build-only"])
            .enforceCanFind(CompilingSourceMessage);
    }

    /* RUND fails at building a lib when the source is in a subdir: https://issues.dlang.org/show_bug.cgi?id=14296 */

    // CURRENTLY NOT WORKING ON MY WINDOWS BOX
    // GET ERROR: The system cannot move the file to a different disk drive.
    {
        enum srcDir = "rundTest";
        mixin(tempDirCode("srcDir"));
        //TempDir srcDir = "rundTest";
        string srcName = srcDir.buildPath("test.d");
        std.file.write(srcName, `void fun() {}`);
        if (exists("test" ~ libExt)) std.file.remove("test" ~ libExt);

        auto targetFile = srcDir.buildPath("test" ~ libExt);
        execPass(rundArgs ~ ["-of=" ~ targetFile, "--build-only", "--force", "-lib", srcName]);
        assert(exists(targetFile));
        assert(!exists("test" ~ libExt));
    }

    // Test with -od
    {
        enum srcDir = "rundTestSrc";
        enum libDir = "rundTestLib";
        mixin(tempDirCode("srcDir"));
        mixin(tempDirCode("libDir"));

        string srcName = srcDir.buildPath("test.d");
        std.file.write(srcName, `void fun() {}`);

        execPass(rundArgs ~ ["--build-only", "--force", "-lib", "-od" ~ libDir, srcName]);
        assert(exists(libDir.buildPath("test" ~ libExt)));

        // test with -od= too
        TempDir altLibDir = "rundTestAltLib";
        execPass(rundArgs ~ ["--build-only", "--force", "-lib", "-od=" ~ altLibDir, srcName]);
        assert(exists(altLibDir.buildPath("test" ~ libExt)));
    }
    // test that 'prog' works before and after creating binary in same directory
    {
        const src = "prog.d";
        const outExe = "prog" ~ binExt;
        const outObj = "prog" ~ objExt;
        makeFileWithRetry(src, `void main() { }`);
        execPass(rundArgs ~ ["-od=.", "prog"]);
        outExe.enforceExists;
        outObj.enforceExists;
        execPass(rundArgs ~ ["-od=.", "prog"]);
        outExe.enforcedRemove;
        outObj.enforcedRemove;
        src.enforcedRemove;
    }

    // Test with -of and --od
    {
        TempDir srcDir = "rundTestSrc";
        TempDir libDir = "rundTestLib";
        TempDir binDir = "rundTestBin";

        const srcName = buildPath(srcDir, "test.d");
        std.file.write(srcName, `void fun() {}`);
        const defaultOutFile = buildPath(libDir, "test" ~ libExt);

        execPass(rundArgs ~ ["--build-only", "--force", "-lib", "--od=" ~ libDir, srcName]);
        defaultOutFile.enforceExists.enforcedRemove;

        const libOutFile = buildPath(libDir, "libtest" ~ libExt);

        execPass(rundArgs ~ ["--build-only", "--force", "-lib", "--od=" ~ libDir, "-of=libtest", srcName]);
        libOutFile.enforceExists.enforcedRemove;

        execPass(rundArgs ~ ["--build-only", "--force", "-lib", "-of" ~ libOutFile, srcName]);
        libOutFile.enforceExists.enforcedRemove;
        const altLibName = libDir.buildPath("altlibtest" ~ libExt);
        execPass(rundArgs ~ ["--build-only", "--force", "-lib", "-of=" ~ altLibName, srcName]);
        altLibName.enforceExists.enforcedRemove;

        auto helloExe = buildPath(binDir, "hello") ~ binExt;
        execPass(rundArgs ~ ["--force", "--od=" ~ binDir, testFiles.hello])
            .enforceCanFind("Hello!");
        helloExe.enforceExists.enforcedRemove;
        execPass(rundArgs ~ ["--force", "--od=" ~ binDir, "-of=hello", testFiles.hello])
            .enforceCanFind("Hello!");
        helloExe.enforceExists.enforcedRemove;
        execPass(rundArgs ~ ["--force", "-of=" ~ helloExe, testFiles.hello])
            .enforceCanFind("Hello!");
        helloExe.enforceExists.enforcedRemove;
    }

    /*
    Test that the build witness works
    TODO: need to that these seven combinations of options use the build witness
      1. -of=<file>
      2. --od=<dir>
      3. --od=<dir> --of=<file>
      4. -od=<dir>
      5. -od=<dir> -of=<file>
      6. -od=<dir> --od=<dir>
      7. -od=<dir> --od=<dir> --of=<file>
    Note that using none of them MUST NOT use the build witness...that should be tested as well
    */
    {
        enum tempPragmaPrintSrc = "pragma_print_temp.d";
        enum outFile = "pragma_print_temp" ~ binExt;

        std.file.write(tempPragmaPrintSrc, PragmaPrintSource);
        execPass(rundArgs ~ ["--od=.", tempPragmaPrintSrc])
            .enforceCanFind(CompilingSourceMessage);
        outFile.enforceExists;
        // Overwrite the out file
        // this will cause the program to be rebuilt because
        // the output file will be newer than the build witness
        makeFileNewerThanNow(outFile, "an invalid binary!");
        execPass(rundArgs ~ ["--od=.", tempPragmaPrintSrc])
            .enforceCanFind(CompilingSourceMessage);
        outFile.enforcedRemove;
        tempPragmaPrintSrc.enforcedRemove;
    }

    /* rund --build-only --force -c main.d fails: ./main: No such file or directory: https://issues.dlang.org/show_bug.cgi?id=16962 */
    {
        enum srcDir = "rundTest";
        mixin(tempDirCode("srcDir"));
        string srcName = srcDir.buildPath("test.d");
        std.file.write(srcName, `void main() {}`);
        string objName = srcDir.buildPath("test" ~ objExt);

        execPass(rundArgs ~ ["-od=" ~ srcDir, "--force", "-c", srcName]);
        assert(exists(objName));
    }

    /* [REG2.072.0] pragma(lib) is broken with rund: https://issues.dlang.org/show_bug.cgi?id=16978 */
    /* GDC does not support `pragma(lib)`, so disable when test compiler is gdmd: https://issues.dlang.org/show_bug.cgi?id=18421
       (this constraint can be removed once GDC support for `pragma(lib)` is implemented) */

    version (linux)
    if (compiler.baseName != "gdmd")
    {{
        enum srcDir = "rundTest";
        mixin(tempDirCode("srcDir"));
        string libSrcName = srcDir.buildPath("libfun.d");
        std.file.write(libSrcName, `extern(C) void fun() {}`);

        execPass(rundArgs ~ ["-od=" ~ srcDir, "-lib", libSrcName]);
        assert(exists(srcDir.buildPath("libfun" ~ libExt)));

        string mainSrcName = srcDir.buildPath("main.d");
        std.file.write(mainSrcName, `extern(C) void fun(); pragma(lib, "fun"); void main() { fun(); }`);

        execPass(rundArgs ~ ["-L-L" ~ srcDir, mainSrcName]);
    }}

    /* https://issues.dlang.org/show_bug.cgi?id=16966 */
    {
        immutable voidMainExe = setExtension(testFiles.voidMain, binExt);

        if (exists(voidMainExe))
            remove(voidMainExe); // make sure it doesn't exist from a previous run

        execPass(rundArgs ~ [testFiles.voidMain]);
        assert(!exists(voidMainExe));
        execPass(rundArgs ~ ["-od=" ~ testFiles.voidMain.dirName, "--build-only", testFiles.voidMain]);
        assert(exists(voidMainExe));
        remove(voidMainExe);
    }

    /* https://issues.dlang.org/show_bug.cgi?id=17198 - rund does not recompile
    when --pass is added */
    {
        TempDir srcDir = "rundTest";
        immutable string src1 = srcDir.buildPath("test.d");
        immutable string src2 = srcDir.buildPath("test2.d");
        std.file.write(src1, "int x = 1; int main() { return x; }");
        std.file.write(src2, "import test; static this() { x = 0; }");

        execFail(rundArgs ~ [src1]);
        execPass(rundArgs ~ ["--pass=" ~ src2, src1]);
        execFail(rundArgs ~ [src1]);
    }

    // test symbolic links to source files
    version (Posix)
    {
        auto link1 = "hello_link.link";
        if (exists(link1))
            remove(link1);
        symlink(testFiles.hello, link1);
        execPass(rundArgs ~ [link1])
            .enforceCanFind("Hello!");
        {
            auto another_link = "hello_link";
            if (exists(another_link))
                another_link.enforcedRemove;
            symlink(testFiles.hello, another_link);
            execPass(rundArgs ~ [another_link])
                .enforceCanFind("Hello!");
            another_link.enforcedRemove;
        }
        auto link2 = "hello_link2.d";
        if (exists(link2))
            remove(link2);
        symlink(link1, link2);
        execPass(rundArgs ~ [link2])
            .enforceCanFind("Hello!");
        execPass(rundArgs ~ [link2.stripExtension])
            .enforceCanFind("Hello!");
        remove(link1);
        execFail(rundArgs ~ [link2])
            .enforceCanFind(format("Error: broken link '%s'", link2));
        remove(link2);
    }

/+
    {
        import std.format : format;

        auto textOutput = buildPath(rundTempDir, "rund_makefile_test.txt");
        if (exists(textOutput))
        {
            remove(textOutput);
        }
        enum makefileFormatter = `.ONESHELL:
SHELL = %s
.SHELLFLAGS = %-(%s %) --eval
%s:
	import std.file;
	write("$@","hello world\n");`;
        string makefileString = format!makefileFormatter(rundArgs[0], rundArgs[1 .. $], textOutput);
        auto makefilePath = buildPath(rundTempDir, "rund_makefile_test.mak");
        std.file.write(makefilePath, makefileString);
        auto make = environment.get("MAKE") is null ? "make" : environment.get("MAKE");
        res = execute([make, "-f", makefilePath]);
        assert(res.status == 0, res.output);
        assert(std.file.read(textOutput) == "hello world\n");
    }
    +/
}

void runConcurrencyTest(string rundApp, string compiler, string model)
{
    // path to rund + common arguments (compiler, model)
    auto rundArgs = rundArguments(rundApp, compiler, model);

    string sleep100 = buildPath(rundTempDir, "delay_.d");
    std.file.write(sleep100, "void main() { import core.thread; Thread.sleep(100.msecs); }");
    auto argsVariants =
    [
        rundArgs ~ [sleep100],
        rundArgs ~ ["--force", sleep100],
    ];
    import std.parallelism, std.range, std.random;
    foreach (rnd; rndGen.parallel(1))
    {
        try
        {
            auto args = argsVariants[rnd % $];
            auto res = execute(args);
            assert(res.status == 0, res.output);
        }
        catch (Exception e)
        {
            import std.stdio;
            writeln(e);
            break;
        }
    }
}

void runFallbackTest(string rundApp, string buildCompiler, string model)
{
    /* https://issues.dlang.org/show_bug.cgi?id=11997
       if an explicit --compiler flag is not provided, rund should
       search its own binary path first when looking for the default
       compiler (determined by the compiler used to build it) */
    if (exists(buildCompiler))
    {
        errorf("cannot create temporary compiler '%s' because it already exists", buildCompiler);
        throw new Exception("cannot create file");
    }

    auto compilerFile = buildPath(rundTempDir, buildCompiler ~ binExt);
    enum emptyMainFile = "emptymain.d";
    std.file.write(emptyMainFile, "int main(){return 0;}");
    {
        // create a "dummy compiler" executable
        auto res = execute([rundApp].addModelSwitch(model) ~ ["-of=" ~ compilerFile, emptyMainFile]);
        if (res.status != 0)
        {
            errorf("failed to compile a psuedo compiler to %s", compilerFile.formatQuotedIfSpaces);
            writeln("----------------------------------");
            writeln(res.output);
            writeln("----------------------------------");
            assert(0);
        }
    }
    scope(success)
    {
        std.file.remove(compilerFile);
        std.file.remove(emptyMainFile);
    }

    {
        //auto res = execute(rundApp ~ [modelSwitch(model), "--force", "--chatty", emptyMainFile]);
        //assert(res.status == 0, res.output);
        // NOTE: not sure if this is the functionality I want yet
        //res.output.enforceCanFind(`spawn ["` ~ compilerFile ~ `",`);
    }
}
