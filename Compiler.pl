#
#  Compilation of Programming Languages
#
#  Basic concepts:
#
#  We can compile source files of different languages into object files.
#  Object files can be combined into static libraries or executables.
#
#  The language of a file determines how that file is compiled.
#  The language used to create an object file also affects how that file is linked.
#  The default configuration supports C, C++ and assembler files;
#  the C++ compiler is used for linking if a C++ file takes part in the compilation,
#  otherwise, the C compiler is used.
#
#  To implement the "if X takes part in compilation, link with X", we use priorities.
#  It is an error if multiple different languages have the highest priority.
#

my %compilers;
my %languages;
my %file_languages;

# Internal/Low-Level: Default compilation rule.
#    compile_default($file, $compiler_var, $flags_var, $opts)
# Compile a file using default logic.
#
# Parameters:
# - $file: file to compile
# - $compiler_var: variable containing the compiler name ('CC'). Caller must have add_variable()'d it.
# - $flags_var: variable containing extra flags ('CFLAGS'). Caller must have add_variable()'d it.
# - $opts: options
#
# Returns list of object files.
sub compile_default {
    my ($file, $compiler_var, $flags_var, $opts) = @_;

    add_variable('OBJ_SUFFIX' => '.o');

    my $compiler = get_variable      ($compiler_var, $opts, $opts->{$file});                # FIXME: caller should do the merging
    my $flags    = get_variable_merge($flags_var,    $opts, $opts->{$file});
    my $obj_ext  = get_variable      ('OBJ_SUFFIX',  $opts, $opts->{$file});

    my ($dir, $stem, $ext) = split_filename($file);
    my $uniq = '';
    while (1) {
        my $base = make_temp_filename("$dir$stem$uniq", $opts, $opts->{$file});
        my $o = $base.$obj_ext;
        if (generate_unique(["$base.d", $o], $file, "$compiler $flags -c $file -o $o -MMD -MP")) {
            rule_add_info($o, "Compiling $file");
            generate_unique("$base.s", $file, "$compiler $flags -S $file -o \$@");
            return ($o);
        }
        ++$uniq;
    }
}

# Internal/Low-Level: Default link rule.
#    compile_link_default($file, $objs, $libs, $linker_var, $opts)
# Link an executable using default logic.
#
# Parameters:
# - $file: executable file
# - $objs: reference-to-list of object files
# - $libs: reference-to-list of libraries
# - $linker_var: variable containing compiler name ('CC'). Caller must have add_variable()'d it.
# - $opts: options
sub compile_link_default {
    my ($file, $objs, $libs, $linker_var, $opts) = @_;

    add_variable(LDFLAGS => '');
    add_variable(LIBS => '');

    my $linker = get_variable($linker_var, $opts);

    my @lib_options = rule_get_link_inputs(@$libs);
    my $ldflags     = get_variable_merge('LDFLAGS', $opts);
    my $extra_libs  = get_variable_merge('LIBS', $opts);

    generate($file,
             [@$objs, grep {!/^-/} @$libs],
             "$linker $ldflags -o \$@ ".join(' ', @$objs, @lib_options, $extra_libs));
    rule_add_info($file, "Linking $file");
    generate(all => $file);
}

# Internal/Low-Level: Find language of a set of files.
#    compile_find_combined_language(@files...)
# Determines the combined language of a set of object/library files,
# i.e. files produced by compile_file(), compile_static_library().
#
# Returns the highest-priority language if that is unique.
# Fails (die) if that is ambiguous.
# Returns undef if the files have no language (i.e. provided as pre-built object files).
sub compile_find_combined_language {
    # FIXME: make it possible to override this?
    my $what = shift;
    my $combined_language;
    my $pri = 0;
    foreach (@_) {
        my $this_language = $file_languages{$_};

        if (defined($this_language) && $compilers{$this_language} && $compilers{$this_language}{link}) {
            if ($compilers{$this_language}{pri} > $pri) {
                # New highest-priority language
                $combined_language = $this_language;
                $pri = $compilers{$this_language}{pri};
            } elsif (defined($combined_language) && $compilers{$this_language}{pri} == $pri && $this_language ne $combined_language) {
                # Mixed languages
                $combined_language = undef;
            } else {
                # Low-priority language, or same as existing highest-priority language
            }
        }
    }

    if ($pri > 0 && !defined($combined_language)) {
        die "Unable to determine language for $what\n";
    }

    $combined_language;
}

#
#  Public Interface
#

# Add a language.
#     compile_add_language($lang, @exts...)
# Defines that files with the given extensions are to be compiled using the given language.
# The language is an arbitrary string. Use compile_add_tool() to add the appropriate tools.
# The extensions need to include a dot.
#
# Example: compile_add_language('C', '.c');
sub compile_add_language {
    my $lang = shift;
    foreach (@_) {
        $languages{$_} = $lang;
    }
}

# Add a language tool.
#    compile_add_tool($lang, $pri, $compile, $link)
# Add tool to compile a language.
# - $lang: name of the language as used in compile_add_language().
# - $pri: priority; integer >= 0.
# - $compile: closure called with parameters ($file, $opts) to compile the given file.
#   Must return the name(s) of created object files.
# - $link: closure called with parameters ($file, $objs, $libs, $opts) to link an executable
#   from the given object files and libraries (references to lists).
sub compile_add_tool {
    my ($lang, $pri, $compile, $link) = @_;
    $compilers{$lang}{pri} = $pri;
    $compilers{$lang}{compile} = $compile
        if $compile;
    $compilers{$lang}{link} = $link
        if $link;
}

# Compile a file.
#    compile_file($file, $opts)
# Compiles the given file into an object file and returns the object file name(s).
# The language is determined from the file name.
#
# This may create zero or more rules, and return zero or more files:
# - header files are not compiled at all
# - object files are returned as-is
sub compile_file {
    my ($file, $opts) = @_;

    # Determine language
    my $ext = (split_filename($file))[2];
    if (!exists($languages{$ext})) {
        die "Unable to determine language of file '$file'\n";
    }

    # Determine whether we can compile this language
    my $language = $languages{$ext};
    if (!exists($compilers{$language}) || !$compilers{$language}{compile}) {
        die "Unable to compile $language, needed for '$file'\n";
    }

    # Compile it
    my @result = $compilers{$language}{compile}($file, $opts);

    # Remember language of this file
    foreach (@result) {
        $file_languages{$_} = $language;
    }

    # Return list of files or first file
    wantarray ? @result : $result[0];
}

# Compile a static library.
#    compile_static_library($stem, $objs, $libs, $opts)
# Compiles the given files into a static library.
#
# Parameters:
# - $stem: name of library (e.g. 'foo' to produce 'libfoo.a')
# - $objs: reference-to-list of object or source files
# - $libs: additional dependencies. Programs that link against this library also link against $libs.
#   Can include "-l", "-L" options.
# - $opts: options
#
# Returns the name of the created library file.
# Users can use that library file or $stem as their own $libs.
sub compile_static_library {
    my ($stem, $objs, $libs, $opts) = @_;

    # Variables
    add_variable(AR => 'ar');
    add_variable(RANLIB => ':');

    my $ar     = get_variable('AR',     $opts, $opts->{$stem});
    my $ranlib = get_variable('RANLIB', $opts, $opts->{$stem});

    # Compile into object files
    my @objs = map {compile_file($_, $opts)} to_list($objs);

    # Build list of linker inputs
    # Librarians don't store path names. If we see a duplicate file name,
    # we therefore need to rename (by copying) the file to a unique name.
    my $out = normalize_filename($V{OUT}, "lib$stem.a");
    my $out_base = md5_hex($out);
    my %basenames;
    my @in;
    foreach (sort @objs) {
        my ($dir, $stem, $ext) = split_filename($_);
        my $uniq = '';
        while (exists $basenames{$stem.$uniq}) {
            ++$uniq;
        }
        $basenames{$stem.$uniq} = 1;

        if ($uniq eq '') {
            # Can accept this file
            push @in, $_;
        } else {
            # Need to renamy/copy
            my $uniq_fn = normalize_filename($V{TMP}, ".lib/$out_base/$stem$uniq$ext");
            generate_copy($uniq_fn, $_);
            rule_add_comment($uniq_fn, "Unique basename for $_ for archiving into $out");
            push @in, $uniq_fn;
        }
    }

    # FIXME: deal with result value failure?
    generate_unique($out, [@in], "$ar cr $out ".join(' ', @in), "$ranlib $out");
    rule_add_info($out, "Archiving $out");
    $file_languages{$out} = compile_find_combined_language($out, @objs);

    # Generate an alias so that 'make foo' makes 'libfoo.a'
    if ($stem ne $out) {
        generate($stem, $out);
        rule_set_phony($stem);
    }

    # Propagate dependencies
    rule_add_link($out, $out, rule_get_link_inputs(to_list($libs)));

    $out;
}

# Compile an executable.
#    compile_executable($exe, $objs, $libs, $opts)
#
# Parameters:
# - $exe: basename of result (EXE_SUFFIX will be added)
# - $objs: reference-to-list of object or source files
# - $libs: libraries. Can include "-l", "-L" options.
# - $opts: options
#
# Returns the name of the created executable file.
sub compile_executable {
    my ($exe, $objs, $libs, $opts) = @_;

    # Variables
    add_variable(EXE_SUFFIX => '');
    add_variable(LIBS => '');

    my $exe_ext = get_variable('EXE_SUFFIX', $opts);
    my $out_dir = get_variable('OUT', $opts);
    my $out = normalize_filename($out_dir, $exe.$exe_ext);

    my @objs = map {compile_file($_, $opts)} to_list($objs);
    my @libs = rule_flatten_aliases(to_list($libs));

    my $combined_language = compile_find_combined_language($exe, @objs, @libs);
    if (defined($combined_language) && $compilers{$combined_language} && $compilers{$combined_language}{link}) {
        # Language-specific linker
        $compilers{$combined_language}{link}($out, \@objs, \@libs, $opts);
    } else {
        # No language known; default to linking with C compiler
        add_variable(CC => 'gcc');
        compile_link_default($out, \@objs, \@libs, 'CC', $opts);
    }

    # Generate an alias so that 'make foo' makes 'foo.exe'
    my $norm_exe = normalize_filename($exe);
    if ($out ne $norm_exe) {
        generate($norm_exe, $out);
        rule_set_phony($norm_exe);
    }

    $out;
}

# Add a prebuilt library.
#    compile_add_prebuilt_library($name, $file, $deps)
# A prebuilt library can be listed as $libs in compile_static_library() or compile_executable().
# It will cause the given $file and possible additional dependencies to be linked.
#
# Parameters:
# - $name: Name of prebuilt library (e.g. 'foo')
# - $file: Library file (e.g. 'libfoo.a')
# - $deps: Additional dependencies (e.g. '["-lm"]')
#
# With the example parameters given above, a program that has 'foo' listed in its $libs
# will be linked with the command line 'libfoo.a -lm'.
#
# Returns $name.
sub compile_add_prebuilt_library {
    my ($name, $file, $deps) = @_;

    # Linker rule:
    #     <stem> : <file.a>
    #        // link = additional linker rules or -l options

    generate($name, $file);
    rule_set_phony($name);
    rule_add_link($name, $file, to_list($deps));
    $name;
}


#
#  Default Configuration
#

##
##  Language C
##
##  Uses variables CC, CFLAGS.
##  Compiles *.c and *.s files.
##  (Assembler files are treated as C here.)
##

compile_add_language("C", qw(.c .s));
compile_add_tool("C", 1,
                 sub {
                     my ($file, $opts) = @_;
                     add_variable(CC => 'gcc');
                     add_variable(CFLAGS => '');
                     compile_default($file, 'CC', 'CFLAGS', $opts);
                 },
                 sub {
                     my ($file, $objs, $libs, $opts) = @_;
                     add_variable(CC => 'gcc');
                     compile_link_default($file, $objs, $libs, 'CC', $opts);
                 });

##
##  Language C++
##
##  Uses variables CXX, CXXFLAGS.
##  Compiles *.cpp, *.cxx, *.cc files.
##

compile_add_language("C++", qw(.cpp .cxx .cc));
compile_add_tool("C++", 2,
                 sub {
                     my ($file, $opts) = @_;
                     add_variable(CXX => 'g++');
                     add_variable(CXXFLAGS => add_variable(CFLAGS => ''));
                     compile_default($file, 'CXX', 'CXXFLAGS', $opts);
                 },
                 sub {
                     my ($file, $objs, $libs, $opts) = @_;
                     add_variable(CXX => 'g++');
                     compile_link_default($file, $objs, $libs, 'CXX', $opts);
                 });

##
##  Special Cases
##
##  Header files are ignored (do not produce a rule).
##  Object files are passed through.
##

compile_add_language("Ignore", qw(.h .hpp .hxx .hh));
compile_add_tool("Ignore", 0, sub { return() }, undef);

compile_add_language("Link", qw(.o .a));
compile_add_tool("Link", 0, sub { return $_[0] }, undef);

