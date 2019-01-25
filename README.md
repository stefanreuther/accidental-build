An Accidental Build System
==========================

This is a simple Makefile generator. It works by building a simple
representation of the Makefile rules in memory, using Perl code, and
then writing out a single, large, standalone Makefile. That Makefile
can then be processed very efficiently by Make.

Key features:

* supports out-of-tree builds

* supports reliable incremental builds (i.e. if a command line
  changes, files are rebuilt)

* description language is Perl, so no need to learn new whacky syntax

* generates very efficient, non-recursive Makefile

* preliminary ninja support



How to Use
----------

In your project, create a file `Rules.pl` containing the rule
generators. The absolute minimum would be something like this to
compile a single C file into a program:

    my $prog = "$V{OUT}/prog";
    my $src = "$V{IN}/prog.c";
    generate($prog, $src, "gcc -o $prog $src");

You would build this project using the following steps:

    mkdir build_dir
    cd build_dir
    perl /path/to/Make.pl IN=/path/to/source
    make

Once you have generated the Makefile, it will auto-regenerate when any
relevant input file changes.

The generated Makefile is *not* intended to be distributed with the
source code.


### Control Structures

You can use any Perl control structures you wish to generate your
rules. For example, to generate a program from multiple objects, you
could use this `Rules.pl`:

    # Compile source code into object code; gather object files in @o
    my @o;
    foreach (qw(one two three four five six seven)) {
        push @o, generate("$V{TMP}/$_.o", "$V{IN}/$_.c", 'gcc -c $< -o $@');
    }

    # Link everything into a program
    generate("$V{OUT}/prog", 'gcc -o $@ '.join(' ', @o));

This program also demonstrates the use of `$<` and `$@` to interpolate
the name of input and output files into a command line.


### Configuration

To avoid hardcoding program names, you can accept configuration on the
command line:

    my $prog = "$V{OUT}/prog";
    my $src = "$V{IN}/prog.c";
    my $cxx = add_variable(CXX => 'gcc');
    generate($prog, $src, "$cxx -o $prog $src");
    # or: generate($prog, $src, '$(CXX) -o $@ $<');

This will allow users to accept a command line such as

    perl /path/to/Make.pl IN=/path/to/source CXXFLAGS=gcc-8.1.0

to change the compilation command.

Likewise, you can do things like

    if (add_variable(WITH_FOO => 0)) {
        # ...
    }

to allow users to configure optional components. This variable can be
set using a parameter such as `WITH_FOO=1`, or more conveniently,
`--with-foo` or `--without-foo`.

The generated Makefile will *not* accept variable assignments. Dealing
with variables would make matters pretty complex, and in particular
make detecting rule changes very hard. All replacements happen at
Makefile generation time.


### What the Makefile does

By default, the Makefile automatically has a `make clean` rule to
remove all generated files except those explicitly marked precious.

The Makefile automatically regenerates itself if any of the files
involved in its creation changes. If the command used to create a file
changes, that file is rebuilt.

You need not manually create subdirectories, this happens
automatically.

The Makefile will have a `make all` rule. You need to add dependencies
to that rule.

If a rule generates a `.d` file, that file will automatically be
included into the Makefile using the `-include` command. By having
your compiler create these files, we get automatic header file
dependencies (for gcc, use `-MMD -MP`).


### Ninja support

Invoke it as

    mkdir build_dir
    cd build_dir
    perl /path/to/Make.pl IN=/path/to/source ninjafile
    ninja

to generate a `build.ninja` file instead of a Makefile. This support
is incomplete and probably not ideal yet.


### More

Check the documentation within `Make.pl` for more information, aka: RTFS.

There also are some ready-made subroutines for autoconf-style
configuration and compilation. Use those by calling a command such as

    load_module('Compiler.pl');

in your `Rules.pl`.



History, or: why?
-----------------

This tool grew from the need to generate assets for web and desktop
applications. This means we have to render a few *.svg or *.pov files
into *.png at various resolutions, composite some, apply some effects,
and copy them to their final location and name.

This is very cumbersome to express in a Makefile (or a CMakeLists.txt
file), and asks for a generator:

    foreach (qw(foo bar baz)) {
        my $in = "$IN/$_.svg";
        my $out = "$OUT/$_.png";
        $rule{$out} = { in=>[$in], code=>["inkskape -e $out $in"] };
    }

It turns out that once we have a representation of Makefile rules in
memory, it is really simple to add things like auto-creation of output
directories, rebuild on rule change...

    foreach (sort keys %rule) {
        my $name_hash = md5_hex($_);
        my $code_hash = md5_hex(join("\n", @{$rule{$_}{code}}); # simplified
        my $hash_file = ".hash/".$name_hash."_".$code_hash;
        push @{$rule{$_}{in}}, $hash_file;
        $rule{$hash_file} = { code =>["rm -f ".$name_hash."_*", "touch $hash_file"] };
    }

...or a "make clean" rule

    $rule{clean} = { code=>[map {"rm -f $_"} sort keys %rule] }

Compiling C++ code is just a matter of different, simple rules. And
since this is Perl, we can use all Perl control structures and
functions.

This, plus some chrome, is essentially everything `Make.pl` does.



Efficiency
-----------

The generated Makefile does not rely on any built-in magic (i.e.
built-in pattern rules) of the Make program. You can disable Make's
builtin rules (GNU make: `-r`) to reduce the number of files it looks
at (this is an advantage ninja claims to have over Make).

The above "asset" project currently clocks in at 365 output files and
2465 temporary files. After a build, GNU make needs 50 ms to determine
that there's nothing more to be done, `make -r` needs just 17 ms on my
machine (ninja: 9 ms). For a C++ project with ~900 source files we're
at 250 ms vs. 50 ms (vs. 16 ms).



Portability
------------

The Makefile will use no variables, functions or special commands
(e.g. conditionals), just plain simple rules. The Makefile will not
use pattern rules (`.c.o:` or `%.o: %.c`).

If a rule generates a `.d` file, that file will automatically be
included into the Makefile using the `-include` command. These are
dependency files.

The Makefile will have a rule to re-create itself; this will obviously
only work if the Make utility supports the feature of re-creating and
re-loading a Makefile.
