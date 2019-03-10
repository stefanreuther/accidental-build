#
#  Configuration ("autoconf")
#

use Digest::MD5 qw(md5_hex);

##
##  Logging
##

sub log_info {
    print "\t", @_, "\n";
}

sub log_trace {
    add_variable('VERBOSE', '');
    if ($V{VERBOSE}) {
        print @_, "\n";
    }
}


##
##  Utilities
##

# Get name of directory to use for configuration purposes
sub file_config_dir {
    my $dir = "$V{TMP}/.conf";
    $dir;
}

# Create a temporary file with given content.
#   file_config_dir($content, $ext)
# Returns the name of the created file.
# The file name is derived from the content, to propagate changes in file content through to the commands.
sub file_create_temp {
    my $content = shift;
    my $ext = shift;
    my $file_name = file_config_dir() . "/" . md5_hex('create_temp:'.$content.$ext) . $ext;
    create_directory_for($file_name);
    open FILE, '>', "$file_name" or die "$file_name: $!";
    print FILE $content;
    close FILE;
    $file_name;
}

# Check whether given file(s) exist at the given path
#   file_exists_at_path($path, @files)
# Returns true if all required files exist.
sub file_exists_at_path {
    my $path = shift;
    foreach (@_) {
        -e normalize_filename($path, $_) or return 0;
    }
    return 1;
}

##
##  Atomic tests
##

# Execute a command.
#   try_exec(@command)
# Returns true if the command succeeds.
sub try_exec {
    my $cmd = join(' ', @_);
    log_trace("Executing '$cmd'...");
    my $err = system("$cmd");
    log_trace("Result: $err");
    return $err == 0 ? 1 : 0;
}

# Execute a command and return its output.
#   try_exec_output(@command)
# Returns command output as string.
sub try_exec_output {
    my $cmd = join(' ', @_);
    log_trace("Executing '$cmd'...");
    my $result = `$cmd`;
    chomp($result);
    $result;
}

# Try compiling a file using CXX/CXXFLAGS.
#   try_compile($file, {var=>$value}, $commit)
# First parameter: file name
# Second parameter: possible overrides to CXX/CXXFLAGS
# Third parameter: if nonzero, automatically set the variables on success
sub try_compile {
    my ($file, $vars, $commit) = @_;
    my $cxx = get_variable('CXX', $vars);
    my $cxxflags = get_variable('CXXFLAGS', $vars);
    my $result = try_exec "$cxx $cxxflags -c $file -o $V{TMP}/.conf/tmp.o >/dev/null 2>&1";
    if ($result && $commit) {
        set_variable(%$vars);
    }
    $result;
}

# Try compiling and linking a file using CXX/CXXFLAGS/LDFLAGS/LIBS.
#   try_compile($file, {var=>$value}, $commit)
# First parameter: file name
# Second parameter: possible overrides to CXX/CXXFLAGS/LDFLAGS/LIBS
# Third parameter: if nonzero, automatically set the variables on success
sub try_link {
    my ($file, $vars, $commit) = @_;
    my $cxx      = get_variable('CXX', $vars);
    my $cxxflags = get_variable('CXXFLAGS', $vars);
    my $ldflags  = get_variable('LDFLAGS', $vars);
    my $libs     = get_variable('LIBS', $vars);

    my $result = try_exec "$cxx $cxxflags $file -o $V{TMP}/.conf/tmp.exe $ldflags $libs >/dev/null 2>&1";
    if ($result && $commit) {
        set_variable(%$vars);
    }
    $result;
}

##
##  High-Level tests
##

# Find compiler. Provides the CXX/CXXFLAGS/CROSS_COMPILE variables.
# If user provided those, verify and use them; otherwise, try to guess.
sub find_compiler {
    add_variable(CXX => '');
    add_variable(CXXFLAGS => '');
    add_variable(CROSS_COMPILE => '');

    my $test_file = file_create_temp("int main() { return 0; }\n", '.cpp');
    if ($V{CXX} eq '') {
        foreach my $cc ("$V{CROSS_COMPILE}g++", "$V{CROSS_COMPILE}c++") {
            if (try_compile($test_file, {CXX => $cc})) {
                set_variable(CXX => $cc);
                last;
            }
        }
        if ($V{CXX} eq '') {
            die "Error: no compiler found";
        }
    } else {
        if (!try_compile($test_file)) {
            die "Error: compiler '$V{CXX}' does not work; provide correct 'CXX=' option";
        }
    }
    log_info("Using C++ compiler: $V{CXX}");
}

# Find compiler options.
#   find_compiler_options(qw(-a -b -c))
# Tries all options and adds those that work to CXXFLAGS.
sub find_compiler_options {
    add_variable(CXXFLAGS => '');

    my $test_file = file_create_temp("int main() { return 0; }\n", '.cpp');
    foreach (@_) {
        try_compile($test_file, {CXXFLAGS => "$_ $V{CXXFLAGS}"}, 1);
    }
    log_info("Using compiler options: $V{CXXFLAGS}");
}

# Find archiver. Provides the AR variable.
# If user provided those, verify and use it; otherwise, use default.
sub find_archiver {
    add_variable(AR => "$V{CROSS_COMPILE}ar");
    my $file = file_config_dir() . '/tmp.a';
    create_directory_for($file);
    if (!try_exec("$V{AR} cr $file >/dev/null 2>&1")) {
        die "Error: archiver '$V{AR}' does not work; provide correct 'AR=' option";
    }
    unlink $file;
    log_info("Using archiver: $V{AR}");
}

# Find system libraries.
#   find_system_libraries(qw(-lfoo -lbar))
# Tries all given libraries and adds those that work to LIBS.
sub find_system_libraries {
    add_variable(LIBS => '');
    my $file_name = file_create_temp("int main() { }\n", ".c");
    if ($V{LIBS} eq '') {
        foreach (@_) {
            try_link($file_name, {LIBS => "$V{LIBS} $_"}, 1);
        }
    } else {
        try_link($file_name)
            or die "Error: the specified library list '$V{LIBS}' does not work; provide correct 'LIBS=' option";
    }
    log_info("Using system libraries: $V{LIBS}");
}

# Find optional program.
#   find_program($key, $program, @opts)
# First parameter: variable to set, typically something like WITH_FOO.
# Second parameter: name of program.
# Options are a list of key=>value pairs:
#    var            variable where to find/place name
#    path           extra paths to search
#    env            extra environment variable to search
#
# Tries to locate the program by looking for an appropriately named executable.
# If --with-foo (WITH_FOO=1) is given, it is an error if it cannot be found,
# if --without-foo (WITH_FOO=0) is given, it is not used.
#
# The program is searched along the PATH environment variable, the given paths,
# or the given environment variable. The program is NOT attempted to be executed.
#
# If 'var' is given, the user can claim the program to be available under a given
# name by specifying this variable, and it will be used with no further checks.
# If the search succeeds, the variable is updated with the resulting path.
sub find_program {
    my $key = shift;
    my $program = shift;
    my %opts = @_;

    add_variable($key => '');
    if ($V{$key} eq '' || $V{$key}) {
        # auto or explicitly enabled
        my $ok = 0;
        my $path;
        if (exists $opts{var} && exists $V{$opts{var}} && $V{$opts{var}} ne '') {
            # user provided a name already (or we saw this in a previous run), assume it works
            $path = $V{$opts{var}};
            $ok = 1;
        } else {
            # no directory given, perform path search
            my @path;
            push @path, split /:/, $opts{path}      if exists $opts{path};
            push @path, split /:/, $ENV{$opts{env}} if exists $opts{env} && exists $ENV{$opts{env}};
            push @path, split /:/, $ENV{PATH}       if exists $ENV{PATH};
            foreach my $p (@path) {
                my $f = normalize_filename($p, $program);
                if (-f $f && -x $f) {
                    $path = $f;
                    $ok = 1;
                    last;
                }
            }
        }

        if (!$ok && $V{$key}) {
            die "Error: unable to find program '$program' although explicitly requested; change '$key='";
        }
        $V{$key} = $ok;
        if ($ok && exists $opts{var}) {
            set_variable($opts{var}, $path);
        }
    }

    if (!$V{$key}) {
        log_info("Disabled $program.");
    }
    $V{$key};
}

# Find library.
#   find_library($key, @opts)
# First parameter: variable to set, typically something like WITH_FOO
# Options are a list of key=>value pairs:
#    program        a program to try-compile
#    libs           default libraries '-lfoo'
#    pkg            name of library in 'pkg-config'
#    name           user-friendly name
#    dir            directory. Suggestion: pass add_variable(FOO_DIR => '').
#
# Tries to locate the library.
# If --with-foo (WITH_FOO=1) is given, it is an error if it cannot be found,
# if --without-foo (WITH_FOO=0) is given, it is not used.
#
# If a 'dir' and 'program' are given, attempts to construct appropriate -L, -I options.
# If 'pkg' is given, attempts to locate the library using pkg-config,
# and optionally verifies it against 'program'.
# pkg-config can be disabled by setting USE_PKGCONFIG=0.
# If everything fails, tries whether just linking against the library already works;
# this is the case if the library is installed as a system library or the user
# has given appropriate CXXFLAGS/LIBS.
sub find_library {
    my $key = shift;
    my %opts = @_;

    # Sanitize parameters
    my $name = $opts{name} || $key;
    my $prog = $opts{program} ? file_create_temp($opts{program}, '.c') : '';
    my $libs = $opts{libs} || '';
    my $dir  = $opts{dir}  || '';
    my $pkg  = $opts{pkg}  || '';

    # Set up output variables
    add_variable($key => '',
                 LIBS => '',
                 CXXFLAGS => '');

    my $use_pkgconfig = find_program('USE_PKGCONFIG', 'pkg-config', var => 'PKGCONFIG');

    if ($V{$key} eq '' || $V{$key}) {
        # auto or explicitly enabled
        my $ok = 0;
        if ($dir ne '' && $prog ne '' && $libs ne '') {
            # Probe provided directory names
            foreach my $d (split /\s+/, $dir) {
                if (-d "$d/lib" && -d "$d/include" && try_link($prog, { LIBS => "$V{LIBS} $libs", LDFLAGS => "$V{LDFLAGS} -L$d/lib", CXXFLAGS => "$V{CXXFLAGS} -I$d/include" }, 1)) {
                    log_info("Enabled $name (standard)");
                    $ok = 1;
                    last;
                }
                if (-d "$d" && try_link($prog, { LIBS => "$V{LIBS} $libs", LDFLAGS => "$V{LDFLAGS} -L$d", CXXFLAGS => "$V{CXXFLAGS} -I$d" }, 1)) {
                    log_info("Enabled $name (flat)");
                    $ok = 1;
                    last;
                }
            }
        }
        if (!$ok && $pkg ne '' && $use_pkgconfig && try_exec("$V{PKGCONFIG} --exists $pkg")) {
            # pkg-config claims it's there
            my $libs = try_exec_output("$V{PKGCONFIG} --libs $pkg");
            my $incs = try_exec_output("$V{PKGCONFIG} --cflags-only-I $pkg");
            my $flags = { LIBS => "$V{LIBS} $libs", CXXFLAGS => "$V{CXXFLAGS} $incs" };
            if ($prog ne '') {
                # We have a test program; verify that pkg-config output is correct
                if (try_link($prog, $flags, 1)) {
                    log_info("Enabled $name (verified pkg-config)");
                    $ok = 1;
                }
            } else {
                # Accept unchecked
                log_info("Enabled $name (pkg-config)");
                set_variable(%$flags);
                $ok = 1;
            }
        }
        if (!$ok && $prog ne '' && $libs ne '') {
            # If still not found, try whether we can link as-is
            # (e.g. if user specified explicit CXXFLAGS/LIBS)
            if (try_link($prog, { LIBS => "$V{LIBS} $libs" }, 1)) {
                log_info("Enabled $name (system)");
                $ok = 1;
            }
        }
        if (!$ok && $V{$key}) {
            die "Error: unable to use $name although explicitly requested; change '$key='";
        }
        $V{$key} = $ok;
    } else {
        # explicitly disabled, do nothing else
    }

    if (!$V{$key}) {
        log_info("Disabled $name.");
    }
    $V{$key};
}

# Find directory.
#   find_directory($key, @opts)
# First parameter: variable to set, typically something like FOO_DIR.
# Options are a list of key=>value pairs:
#    name           user-friendly name
#    files          reference to list of file names that need to be in the directory
#    guess          reference to list of guesses for the directory name
#
# If files are given, they need to be present in a directory to be acceptable.
# If guesses are given, they are tried (check files, or just presence of directory)
# to find a directory if none is given.
sub find_directory {
    my $key = shift;
    my %opts = @_;

    # Sanitize parameters
    my $name = $opts{name} || $key;
    my @files = to_list($opts{files});

    # Guess directory if needed
    my $dir = add_variable($key => '');
    if ($dir eq '') {
        foreach my $d (to_list($opts{guess})) {
            if (@files ? file_exists_at_path($d, @files) : -d $d) {
                $dir = $d;
                last;
            }
        }
    }

    # Postprocess
    # FIXME: should be able to report "not found"
    if ($dir eq '' || (@files && !file_exists_at_path($dir, @files))) {
        die "Error: please specify correct directory for $name\n";
    }
    $dir = normalize_filename($dir);
    set_variable($key, $dir);
    log_info("Using $key: $dir");
    $dir;
}
