# rund

A compiler-wrapper that runs and caches D programs.

This is a rewrite of `rdmd` that depends on the "include imports" feature introduced in dmd version `2.079` (enabled via `-i`). This feature allows `rund` to do everything `rdmd` was able to do in one invocation of the compiler instead of two.

# Build/Test/Install

The build/test/install code is written in D and contained in `make.d`.  If you already have `rund` compiled and installed, you can use that to run `make.d`, otherwise, you can use the compiler directly to run it:

> NOTE: there is a bug on windows where using `dmd -run` will introduce a `LINKCMD` environment variable that will set the linker to `OPTLINK` but then further invocations of dmd with a model set (i.e. `-m64`) will use the Microsoft linker.  This makes `dmd` use the Microsoft linker command line interface with OPTLINK!

### Build rund
This will build `rund` and make it available in the `bin` directory:

Using rund:
```
./make.d build
# OR
rund make.d build
```
Using the compiler directly:
```
dmd -Isrc -i -run make.d build
```

### Test rund
This will build `rund` if it needs to be built and then test it:

Using rund:
```
./make.d test
# OR
rund make.d test
```
Using the compiler directly:
```
dmd -Isrc -i -run make.d test
```

### Install rund
This will install `rund` to a directory in your path.  It will interactively show installation path candidates and query the user to select which one to install `rund` to.

Using rund:
```
./make.d install
# OR
rund make.d install
```
Using the compiler directly:
```
dmd -Isrc -i -run make.d install
```

# Source Compiler Directives

rund supports "compiler directives" in the main source file.  Each directive line starts with `//!` and must appear at the beginning of the file but after the shebang line (i.e. `#!/usr/bin/env rund`) line if present.

```D
#!/usr/bin/env rund
//!importPath <path>
//!version <version>
//!library <library_file>
//!importFilenamePath <path>
//!env <var>=<value>
```

### Idea

For more complex situations, we could support configuring the build via D code!
```D
/*!
//
// This is a block of code that rund will execute to configure the build.
// One idea is to have this code be interpreted as if it exists inside a function.
// Maybe a function like this?
// void configureBuild(Config config) ?
//
version (Windows)
{
    config.importPathList.put("windows");
}
else
{
    config.importPathList.put("posix");
}
*/
```
Or another syntax:
```D
version (ConfigureBuild)
{
    config.importPathList.put("src");
    version(Windows)
        config.libraryList.put("kernel32.lib");
    else
        config.libraryList.put("stdc.lib");
}
```
Or maybe this could go in a separate file?
```D
//!buildConfig configureBuild.d
```
