module rund.deps;

import std.typecons : Flag, Yes, No;
import std.range : chain;
import std.string : startsWith, endsWith, chomp, split;
import std.format : format;
import std.algorithm : filter;
import std.datetime : SysTime;
import std.path : buildPath, buildNormalizedPath, baseName, absolutePath, relativePath, isRooted, pathSeparator;
import std.file : getcwd;
import std.process : environment;

import rund.common;
import rund.chatty;

immutable defaultExclusionPackages = ["std", "etc", "core"];

struct FileRebaser
{
    private string rebaseDir;
    this(string otherCwd)
    {
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
        if (rebaseDir is null) return path;
        return path.isRooted ? path : buildNormalizedPath(rebaseDir, path);
    }
    string yapCorrectedPath(string logName, string path)
    {
        auto result = correctedPath(path);
        yapf("%s %s => %s", logName, path.formatQuotedIfSpaces, result.formatQuotedIfSpaces);
        return result;
    }
}

// Assumption: filename exists
string[string] readJsonFile(string jsonFilename, string objDir)
{
    import std.json : parseJSON, JSONValue;

    auto jsonText = Chatty.readText(jsonFilename);
    auto json = parseJSON(jsonText).object;

    string[string] result;
    FileRebaser fileRebaser;
    {
        auto buildInfo = json["buildInfo"].object;
        {
            auto cwdProperty = buildInfo["cwd"].str;
            yapf("buildInfo.cwd %s", cwdProperty.formatQuotedIfSpaces);
            fileRebaser = FileRebaser(cwdProperty);
        }
        {
            auto configFilename = fileRebaser.yapCorrectedPath("buildInfo.config", buildInfo["config"].str);
            result[configFilename] = null;
        }
        {
            auto libraryProperty = buildInfo.get("library", JSONValue.init);
            if (!libraryProperty.isNull)
            {
                auto libPath = findLib(libraryProperty.str);
                yap("library ", libraryProperty, " ", libPath);
                result[libPath] = null;
            }
        }
    }
    {
        auto compilerInfo = json["compilerInfo"].object;
        // TODO: this will change after 2.079, might need to use buildInfo.argv0
        auto maybeBinary = compilerInfo.get("binary", JSONValue.init);
        if (!maybeBinary.isNull)
            result[maybeBinary.str] = null;
    }
    {
        auto semantics = json["semantics"].object;
        foreach (module_; semantics["modules"].array)
        {
            {
                auto contentImports = module_.object.get("contentImports", JSONValue.init);
                if (!contentImports.isNull)
                {
                    foreach (contentImport; contentImports.array)
                    {
                        result[contentImport.str] = null;
                    }
                }
            }
            {
                auto filenameProperty = module_["file"].str;
                auto nameNode = module_.object.get("name", JSONValue.init);
                bool ignoreAsDependency = false;
                if (!nameNode.isNull)
                {
                    ignoreAsDependency = ignoreModuleAsDependency(nameNode.str, filenameProperty);
                }
                if (!ignoreAsDependency)
                {
                    auto filename = fileRebaser.yapCorrectedPath("module", filenameProperty);
                    result[filename] = d2obj(objDir, filename);
                }
            }
        }
    }
    return result;
}


string d2obj(string objDir, string dfile)
{
    return buildPath(objDir, dfile.baseName.chomp(".d") ~ objExt);
}

// TODO: look into this...
string findLib(string libName)
{
    // This can't be 100% precise without knowing exactly where the linker
    // will look for libraries (which requires, but is not limited to,
    // parsing the linker's command line (as specified in dmd.conf/sc.ini).
    // Go for best-effort instead.
    string[] dirs = ["."];
    foreach (varName; ["LIB", "LIBRARY_PATH", "LD_LIBRARY_PATH"])
    {
        auto dir = environment.get(varName, null);
        if (dir.length > 0)
            dirs ~= dir.split(pathSeparator);
    }
    version (Windows)
        string[] names = [libName ~ ".lib"];
    else
    {
        string[] names = ["lib" ~ libName ~ ".a", "lib" ~ libName ~ ".so"];
        dirs ~= ["/lib", "/usr/lib"];
    }
    foreach (dir; dirs)
    {
        foreach (name; names)
        {
            auto path = buildPath(dir, name);
            if (Chatty.exists(path))
                return absolutePath(path);
        }
    }
    return null;
}

bool ignoreModuleAsDependency(string moduleName, string filename)
{
    if (filename.endsWith(".di") || moduleName == "object" || moduleName == "gcstats")
        return true;

    foreach (string exclusion; defaultExclusionPackages)
        if (moduleName.startsWith(exclusion ~ '.'))
            return true;

    return false;

    // another crude heuristic: if a module's path is absolute, it's
    // considered to be compiled in a separate library. Otherwise,
    // it's a source module.
    //return isabs(mod);
}


// Is any file newer than the given file?
auto anyNewerThan(T)(T files, in string file)
{
    return files.anyNewerThan(file.timeLastModified);
}

// Is any file newer than the given file?
auto anyNewerThan(T)(T files, SysTime t)
{
    import std.parallelism : taskPool;

    typeof(files.front) result;
    foreach (source; taskPool.parallel(files))
    {
        if (!result && source.newerThan(t))
        {
            result = source;
        }
    }
    return result;
}

/**
If force is true, returns true. Otherwise, if source and target both
exist, returns true iff source's timeLastModified is strictly greater
than target's. Otherwise, returns true.
*/
private bool newerThan(string source, string target)
{
    return source.newerThan(Chatty.timeLastModified(target, SysTime.min));
}
private bool newerThan(string source, SysTime target)
{
    // RDMD_FIX: no need for an exception handler here
    return Chatty.timeLastModified(source, SysTime.max) > target;
}

