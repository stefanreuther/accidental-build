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

* generates very efficient, non-recursive Makefile: you can disable
  Make's builtin rules (GNU make: `-r`) to reduce the number of files
  it looks at (one of the advantages claimed by ninja)



How to Use
----------

In your project, create a file `Rules.pl` containing the rule
generators. The absolute minimum would be something like this to
compile a single C file into a program:

    my $prog = "$V{OUT}/prog";
    my $src = "$V{IN}/prog.c";
    generate($prog, $src, "gcc -o $prog $src");
    output_makefile();

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
        my $in = "$V{IN}/$_.c";
        my $out = "$V{TMP}/$_.o";
        generate($out, $in, "gcc -c $in -o $out");
        push @o, $out;
    }

    # Link everything into a program
    generate("$V{OUT}/prog", "gcc -o $V{OUT}/prog ".join(' ', @o));

    # Create makefile
    output_makefile();


### Configuration

To avoid hardcoding program names, you can accept configuration on the
command line:

    my $prog = "$V{OUT}/prog";
    my $src = "$V{IN}/prog.c";
    my $cxx = add_variable(CXX => 'gcc');
    generate($prog, $src, "$cxx -o $prog $src");
    output_makefile();

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
make detecting rule changes very hard.


### More

Check the documentation within `Make.pl` for more information.

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

