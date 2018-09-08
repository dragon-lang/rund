# rund

A compiler-wrapper that runs and caches D programs.

This is a rewrite of `rdmd` that runs about twice as fast. It does so by utilizing the new "include imports" feature (the `-i` command line option) to compile D programs and their dependencies with only one invocation of the compiler.  Since `rdmd` does not use this feature, it must invoke the compiler twice which causes it to take about twice as long.

`rund` also introduces the concept of "Source Compiler Directives" (see below) that allow D source files to contain compiler configuration such as import paths, versions, environment variables, etc.

> Note that the "include imports" feature was introduced in dmd version 2.079 (March 2018).  `rund` will not work with older compilers that do not support this feature.

# Build/Test/Install

The build/test/install code is written in D and contained in `make.d`.  If you already have `rund` compiled and installed, you can use that to run `make.d`, otherwise, you can use the compiler directly to run it:

> NOTE: there is a bug on windows where using `dmd -run` will introduce a `LINKCMD` environment variable that will set the linker to `OPTLINK` but then further invocations of dmd with a model set (i.e. `-m64`) will use the Microsoft linker.  This makes `dmd` use the Microsoft linker command line interface with OPTLINK!

### Build rund

Any of the following will build `rund` in the `bin` directory:

Using dmd:
```
dmd -i -I=src -run make.d build
```

Using an existing rund:
```
./make.d build
```

Using an existing rund explicitly (for Windows):
```
rund make.d build
```

### Install rund

Any of the following will install `rund` alongside the `dmd` compilers in your PATH:

Use rund to install itself:
```
./bin/rund make.d install
```

Use an existing rund:
```
./make.d install
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
//!noConfigFile
//!betterC
```

### Test rund

This will build `rund` if it needs to be built and then test it:

```
./make.d test
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
