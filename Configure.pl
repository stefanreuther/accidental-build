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

# Find library.
#   find_library($key, $libs, $prog, $name)
# First parameter: variable to set, typically something like WITH_FOO
# Second parameter: library options to add, '-lfoo'
# Third parameter: test program content
# Fourth parameter: user-friendly name.
#
# Tries to link $prog against $libs, and sets $key (WITH_FOO) to 1 if it works.
# If user gave a "--with-foo" option, verifies that it works and fails if not.
sub find_library {
    my $key = shift;
    my $libs = shift;
    my $prog = shift;
    my $name = shift || $key;

    add_variable($key => '',
                 LIBS => '');

    my $file_name = file_create_temp($prog, '.c');
    my $flags = {LIBS => "$V{LIBS} ".$libs};
    if ($V{$key} eq '') {
        # auto
        set_variable($key, try_link($file_name, $flags, 1));
    } elsif ($V{$key}) {
        # explicitly enabled
        if (!try_link($file_name, $flags, 1)) {
            die "Error: unable to use $name although explicitly requested; change '$key='";
        }
    } else {
        # explicitly disabled
    }
    if ($V{$key}) {
        log_info("Enabled $name.");
    } else {
        log_info("Disabled $name.");
    }
}
