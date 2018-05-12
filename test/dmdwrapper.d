#!/usr/bin/env rund
//!env CC=c++
//!version MARS
//!importPath ../../dmd/src
//!importFilenamePath ../../dmd/res
//!importFilenamePath ../../dmd/generated/linux/release/64
//!library ../../dmd/generated/linux/release/64/newdelete.o
//!library ../../dmd/generated/linux/release/64/backend.a
//!library ../../dmd/generated/linux/release/64/lexer.a

/*
This wrapper can be used to compile/run dmd (with some caveats).

* You need to have the dmd repository cloned to "../../dmd" (relative to this file).
* You need to have built the C libraries.  You can build these libraries by building dmd.

Note sure why, but through trial and error I determined that this is the
minimum set of modules that I needed to import in order to successfully
include all of the symbols to compile/link dmd.
*/
import dmd.eh;
import dmd.dmsc;
import dmd.toobj;
import dmd.iasm;
