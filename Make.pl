#!/usr/bin/perl -w
use strict;
use Digest::MD5 qw(md5_hex);

# Rules
#    in : [str]          input files
#    out : [str]         output files
#    code : [str]        commands
#    dir : int           is this a directory? (excempt from hash generation)
#    pri : int           order for output, highest at front
#    comment : [str]     comment
#    info : str          info/status message
#    phony : int         true for phony rule
#    precious : int      true for precious file (exempt from 'clean')
my %rules;

# List of directory variables
my @dir_vars;

# List of input files
my @input_files;

# Commands
my %commands;

# Main
my %V = (
    OUT => '.',
    IN => '.',
    TMP => 'tmp',
    INFILE => 'Rules.pl'
);
my %user_vars;

add_directory_variable(qw(OUT IN TMP));
setup_commands();

# Parse parameters
my @args;
foreach (@ARGV) {
    if (/^--?in=(.*)/) {
        set_user_variable(IN => $1);
    } elsif (/^--?out=(.*)/) {
        set_user_variable(OUT => $1);
    } elsif (/^--?infile=(.*)/) {
        set_user_variable(INFILE => $1);
    } elsif (/^--?outfile=(.*)/) {
        set_user_variable(OUTFILE => $1);
    } elsif (/^--?help$/) {
        print "Usage: $0 [--in=INPUT-DIR] [--out=OUTPUT-DIR] [--infile=Rules.pl] [--outfile=Makefile] [VAR=VALUE]\n";
        exit 0;
    } elsif (/^--?(with|enable)-([-\w\d_]+)$/) {
        set_user_variable('WITH_'._sanitize_variable_name($2), 1);
    } elsif (/^--?(without|disable)-([-\w\d_]+)$/) {
        set_user_variable('WITH_'._sanitize_variable_name($2), 0);
    } elsif (/^-/) {
        die "$0: unrecognized option \"$_\"\n";
    } elsif (/^(.*?)=(.*)/) {
        set_user_variable($1, $2);
    } else {
        push @args, $_;
    }
}
generate('all', []);
rule_set_phony('all');
rule_set_priority('all', 100);
load_file("$V{IN}/$V{INFILE}");

# Process command
my $cmd = shift @args;
if (!defined($cmd)) { $cmd = '' }
if (!defined($commands{$cmd})) {
    die "$0: unknown command '$cmd'\n";
}
$commands{$cmd}->(@args);
exit 0;


##
##  Command Interface
##

sub setup_commands {
    $commands{''} = $commands{makefile} = sub {
        output_makefile();
    };
    $commands{ninjafile} = sub {
        output_ninja_file();
    };
    $commands{scriptfile} = sub {
        output_script_file(@args);
    };
    $commands{"show-vars"} = sub {
        show_variables();
    };
}


##
##  General Infrastructure
##

# Create a directory.
#    generate_directory($x)
# Makes a rule to create the directory $x.
# Parents will also be created.
#
# Returns name to use as dependency.
# All files within that directory should depend on this name.
sub generate_directory {
    my $dir = normalize_filename(shift);
    my $mark = "$dir/.mark";
    if (!exists($rules{$mark})) {
        my $mkdir = add_variable('MKDIR', 'mkdir');
        my $touch = add_variable('TOUCH', 'touch');
        my $rule = { in => [], out => [$mark], code => ["-\@$mkdir -p $dir", "\@$touch $mark"], dir => 1, pri => -99, precious => 1 };
        $rules{$mark} = $rule;
        if ($dir =~ m|^(.*)/|) {
            push_unique($rule->{in}, generate_directory($1));
        }
    }
    $mark;
}

# Generate files.
#    generate($out, $in, @cmds)
# This is the main function to generate a Makefile rule.
# $out and $in are either strings (single file) or list references (multiple files).
# This will generate a rule that creates $out from $in using the given commands $cmds.
#
# If a rule with the same outputs already exists, it is extended: additional inputs added,
# additional commands added. For example, `generate("all", X)` adds X to the `make all`
# target; `generate("clean", [], "rm X")` adds a command to `make clean`.
#
# It is an error to add a rule with multiple outputs if different rules already exist for individual outputs.
# For example,
#    generate('a', [], 'cmd a');
#    generate('b', [], 'cmd b');
#    generate(['a', 'b'] [], 'cmd a+b');
# will not work. In contrast,
#    generate(['a', 'b'] [], 'cmd a+b');
#    generate('a', [], 'cmd a');
#    generate('b', [], 'cmd b');
# will work, as the first rule to mention a and b establishes that both are created in one rule,
# and the second and third calls extend that rule.
#
# Variables will be expanded in the commands. Syntax is similar to Makefiles, that is,
# `$X` for single-character names, `$(XX)` for longer names. Variables added with
# `add_variable()`, `set_variable()` are recognized in addition to
#    $$ - dollar sign
#    $@ - first output
#    $< - first input
#
# Returns the first element of $out.
sub generate {
    my @out = map {normalize_filename($_)} to_list(shift);
    my @in  = map {normalize_filename($_)} to_list(shift);

    # Variable expansion
    my @code = @_;
    foreach (@code) {
        s{\$(?:\((.*?)\)|(.))}{
            $+ eq '$' ? '$' :
            $+ eq '@' ? (@out ? $out[0] : '') :
            $+ eq '<' ? (@in  ? $in[0]  : '') :
            get_variable($+)
        }eg;
    }

    # Check for existing rule and find priority along the way
    my $rule;
    my $pri = 0;
    foreach (@out) {
        if (exists $rules{$_}) {
            if (!defined $rule) {
                $rule = $rules{$_}
            } elsif ($rule ne $rules{$_}) {
                die "Cannot merge these rules.\n".
                    "Requested:  ".join(' ',@out)."\n".
                    "Existing 1: ".join(' ',@{$rule->{out}})."\n".
                    "Existing 2: ".join(' ',@{$rules{$_}{out}})."\n";
            }
        }
        if (/^\./) {
            $pri = 2;
        }
    }

    # Remember the rule
    if (defined $rule) {
        push_unique($rule->{out}, @out);
        push_unique($rule->{in}, @in);
        push @{$rule->{code}}, @code;
        foreach (@out) {
            $rules{$_} = $rule;
        }
    } else {
        $rule = { in => [@in], out => [@out], code => [@code], dir => 0, pri => $pri };
        foreach (@out) {
            $rules{$_} = $rule;
        }
    }

    # Add directories
    foreach (@out) {
        if (!m!^(\.\./|/)! && m|^(.*)/|) {
            push_unique($rule->{in}, generate_directory($1));
        }
    }

    $out[0];
}

# Generate unique rule.
#    generate_unique($out, $in, @cmds)
# This is the same as generate(), but will not extend an existing rule.
#
# Success cases: generate_unique() returns 1 if...
# - the rule does not yet exist, it is created.
# - the rule exists and has identical content
#
# Failure case: generate_unique() returns 0 if...
# - the rule already exists and has different content
#
# Use this if you wish to exercise some control over the created file names,
# but are ready to take a plan B if there is a file name conflict.
# For example, a `foo.cpp` file will typically be compiled into `foo.o`,
# but the output file will have to be renamed if the C++ file is compiled
# twice with different options.
sub generate_unique {
    my @out = map {normalize_filename($_)} to_list(shift);
    my @in  = map {normalize_filename($_)} to_list(shift);

    # Check for existing rule and find priority along the way
    my $rule;
    my $pri = 0;
    foreach (@out) {
        if (exists $rules{$_}) {
            if (!defined $rule) {
                $rule = $rules{$_}
            } else {
                return 0
                    if $rule ne $rules{$_};
            }
        }
    }

    if (defined($rule)) {
        # Found a rule. It must contain all outputs, all inputs, and all commands.
        return is_subset([@in], $rule->{in})
            && is_subset([@out], $rule->{out})
            && is_subset([@_], $rule->{code});
    } else {
        # Not found, add anew
        generate([@out], [@in], @_);
        return 1;
    }
}

# Generate anonymous rule.
#    generate_anonymous($out_ext, $in, @cmds)
# This is the same as generate(), but you do not specify a target file name,
# just an extension (".o"). Use this function for temporary files, where you do not
# care about the actual file name.
#
# You need to use `$@` to refer to the output file in the commands.
#
# If an identical rule already exists, it is re-used.
#
# This function returns the name of the created file.
sub generate_anonymous {
    my $out_ext = shift;
    my @in      = to_list(shift);
    my @cmds    = @_;
    my $hash    = md5_hex(join('|', 'anon', $out_ext, @in, '|', @cmds));
    my $out     = "$V{TMP}/.anon/$hash$out_ext";

    if (!exists $rules{$out}) {
        generate($out, \@in, @cmds);
    }

    $out;
}

# Copy a file.
#    generate_copy($out, $in)
# Canned rule for just copying a file around.
sub generate_copy {
    my ($out, $in) = @_;
    my $cp = add_variable('CP', 'cp');
    generate($out, $in, "\@$cp $in $out");
}

# Copy files to a directory.
#    generate_copy_to_dir($out, @in...)
# Shortcut for copying multiple files.
sub generate_copy_to_dir {
    my $dir = shift;
    map {
        my ($in_dir, $base, $ext) = split_filename($_);
        generate_copy(normalize_filename($dir, $base.$ext), $_);
    } @_;
}

# Set priority of a rule.
#    rule_set_priority($rule, $pri)
# High priorities place the rule at the beginning of the Makefile, low priorities at the end.
sub rule_set_priority {
    my ($rule, $pri) = @_;
    _rule_get($rule)->{pri} = $pri;
    $rule;
}

# Add comment to a rule.
#    rule_add_comment($rule, $text...)
# The comment will be output to the Makefile just before the rule.
# You can add multiple comments, each creating one line.
sub rule_add_comment {
    my $rule = shift;
    push @{_rule_get($rule)->{comment}}, @_;
    $rule;
}

# Add information to a rule.
#    rule_add_info($rule, $info)
# The rule information will be printed when the rule is executed.
# For example, `rule_add_info("foo.o", "Compiling foo.c");`
sub rule_add_info {
    my ($rule, $info) = @_;
    _rule_get($rule)->{info} = $info;
    $rule;
}

# Make rules phony.
#    rule_set_phony(@rules...)
# Phony rules do not create actual files, but are only intended to invoke particular command sequences,
# such as `make test`.
sub rule_set_phony {
    foreach (@_) {
        _rule_get($_)->{phony} = 1;
    }
}

# Make files precious.
#    rule_set_precious(@rules...)
# Precious files are not deleted by `make clean`.
sub rule_set_precious {
    foreach (@_) {
        _rule_get($_)->{precious} = 1;
    }
}

# Add link inputs.
#    rule_add_link($rule, @link_inputs)
# If a target depends on a rule, and rule_add_link() has been called for that rule,
# it will depend on @link_inputs instead.
#
# If $rule is a library to be linked, @link_inputs must also mention it.
# @link_inputs can also contain linker switches, i.e. "-lfoo".
#
# For example,
#    rule_add_link('libfoo.a', 'libfoo.a libbar.a -lpthread')
# declares that all programs that depend to `libfoo.a` will actually depend on both `libfoo.a`
# and `libbar.a`, and also link with `-lpthread`; see `rule_get_link_inputs`.
sub rule_add_link {
    my $rule = shift;
    push @{_rule_get($rule)->{link}}, @_;
    $rule;
}

# Flatten aliases.
#    rule_flatten_aliases(@rules...)
# A phony rule of the form "foo : libfoo.a" is called an alias;
# here, 'foo' is a convenience name, and 'libfoo.a' is the actual file.
# Given a list of rule names, this function replaces all phony rules by their dependees, recursively.
# Names that do not map to rules are passed through as-is; in particular, "-lfoo' switches.
# As an exception, if the rule specifies linker inputs, it is returned as is and not expanded.
sub rule_flatten_aliases {
    my @todo = @_;
    my @result;
    my %did;
    while (@todo) {
        my $item = shift @todo;
        if ($did{$item}++) {
            # Already did this one, avoid loop
        } elsif ($rules{$item} && $rules{$item}{phony} && !$rules{$item}{link}) {
            # Phony rule (=alias); expand
            unshift @todo, @{$rules{$item}{in}};
        } else {
            # Regular rule or special item
            push_unique(\@result, $item);
        }
    }
    @result;
}

# Get linker inputs.
#    rule_get_link_inputs(@rules...)
# If a rules has linker inputs (rule_add_link), returns those; otherwise, returns just the rule names.
sub rule_get_link_inputs {
    my @result;
    foreach my $item (@_) {
        if ($rules{$item} && $rules{$item}{link}) {
            # Link special
            push_unique_last(\@result, @{$rules{$item}{link}});
        } else {
            # Regular
            push_unique_last(\@result, $item);
        }
    }
    @result;
}

# Get rule inputs.
#    rule_get_inputs(@rules...)
# If the rule's inputs include libraries (rule_add_link), does the appropriate replacement.
sub rule_get_inputs {
    my @result;
    foreach my $item (@_) {
        if ($rules{$item}{in}) {
            push_unique_last(\@result, rule_get_link_inputs(@{$rules{$item}{in}}));
        }
    }
    @result;
}

# Make an auto-rebuild rule for a directory.
#    rule_rebuild_directory($dir)
# If the content of the directory changes, the directory is deleted (rm -rf) and rebuilt.
# This is normally not done because building directory content can be expensive (e.g.
# compilation of hundreds of object files); only individual files are removed if their
# rule changes. However, auto-rebuild makes sense for a "make dist" rule which populates
# a directory by copying from previously-built stuff; that will typically be much cheaper.
sub rule_rebuild_directory {
    # FIXME: do we need to work recursive?
    my $dir = normalize_filename(shift);
    my $mark = "$dir/.mark";
    if (!$rules{$mark}{dir}) {
        die "No rule for directory '$dir' present\n"
    }

    # Gather all children. Those depend on our .mark file.
    my @children;
    foreach my $k (sort keys %rules) {
        if (grep {$_ eq $mark} @{$rules{$k}{in}}) {
            push @children, $k;
        }
    }

    # Variables
    my $rm = add_variable('RM', 'rm -f');
    my $touch = add_variable('TOUCH', 'touch');

    # Generate hash rule
    my $child_hash = md5_hex(join("\n", sort @children));
    my $name_hash = md5_hex($mark);
    my $n1 = substr($name_hash, 0, 2);
    my $n2 = substr($name_hash, 2);
    my $hash_file = "$V{TMP}/.hash/$n1/${n2}_${child_hash}";
    generate($hash_file, [],
             "\@$rm $V{TMP}/.hash/$n1/${n2}_*",
             "\@$rm -r $dir",
             "\@$touch $hash_file");
    push_unique($rules{$mark}{in}, $hash_file);
    rule_set_priority($hash_file, -100);
    rule_add_comment($hash_file, "Rule change marker for $dir");
}


sub _rule_get {
    my $rule = normalize_filename(shift);
    $rules{$rule} or die "Rule '$rule' does not exist\n";
}


##
##  Special-Purpose Rules
##

# Internal: Generate rebuild rule.
#   generate_rebuild_rule()
# The rule will automatically rebuild the Makefile if any input file changed.
sub generate_rebuild_rule {
    my $mf = normalize_filename(get_variable('OUTFILE'));
    add_variable('PERL', $^X);
    generate($mf, [@input_files, $0],
             join(' ',
                  "$V{PERL} $0 makefile",
                  map {$_.'='.quotemeta($user_vars{$_})} sort keys %user_vars));
    rule_add_comment($mf, 'Automatically regenerate build file');
    rule_add_info($mf, "Rebuilding $mf");
    rule_set_precious($mf);

    # Add a blank 'foo :' rule for each input file (same as 'gcc -MP' would do).
    # This way, a rebuild will work properly if an include file has been moved.
    # Rules must be marked precious so generate_clean_rule() will not delete them.
    # We need to add these rules by hand, because generate() would helpfully try
    # to create the containing directories, causing source directories to be littered
    # with '.mark' files.
    foreach (@input_files, $0) {
        if (!$rules{$_}) {
            $rules{$_} = { in => [], out => [$_], precious => 1, code => [], pri => 0 };
        }
    }
}

# Internal: Generate .PHONY rule.
#   generate_phony_rule()
# Adds a '.PHONY' rule for all rules marked with rule_set_phony().
sub generate_phony_rule {
    my @phony_targets;
    foreach (sort keys %rules) {
        push @phony_targets, $_
            if $rules{$_}{phony};
    }
    generate('.PHONY', [@phony_targets]);
    rule_set_phony('.PHONY');
}

# Internal: Generate `clean` rule.
#   generate_clean_rule()
# This rule will remove all outputs not marked rule_set_phony() or rule_set_precious().
sub generate_clean_rule {
    my %files;
    foreach (keys %rules) {
        if (!$rules{$_}{precious} && !$rules{$_}{phony}) {
            foreach (@{$rules{$_}{out}}) {
                $files{$_} = 1
            }
        }
    }

    my @files = sort keys %files;
    my @cmds;
    my $line = '';
    my $n = 0;
    my $rm = add_variable('RM', 'rm -f');
    foreach (@files) {
        ++$n;
        $line .= ' '.$_;
        if (length($line) > 120) {
            push @cmds, $rm.$line;
            $line = '';
            if (@cmds % 100 == 0) {
                push @cmds, sprintf ("echo \"\tCleaning up (%d%%)...\"", 100 * $n / scalar(@files));
            }
        }
    }
    push @cmds, $rm.$line
        if $line ne '';
    if (@cmds > 100) {
        push @cmds, "echo Done.";
    }

    generate('clean', [], @cmds);
    rule_set_phony('clean');
    rule_add_info('clean', 'Cleaning up');
}

# Internal: Generate rule hashes.
#    generate_rule_hashes()
# Builds makefile rules that will make rules rerun if the rule content changes,
# even if the input files are unchanged.
sub generate_rule_hashes {
    # The idea is to generate a marker file "xx_yy", where "xx" identifies the file in question, and "yy" identifies the rule content.
    # If rule content changes, removing "xx_*" will remove old rule hashes.
    my $rm = add_variable('RM', 'rm -f');
    my $touch = add_variable('TOUCH', 'touch');

    # Build rule hashes for all targets except directories (no need to track) and phony rules (will rerun anyway).
    my %hashes;
    foreach (keys %rules) {
        $hashes{$_} = md5_hex(join("\n", join(' ', @{$rules{$_}{in}}), @{$rules{$_}{code}}))
            unless $rules{$_}{dir} || $rules{$_}{phony};
    }

    foreach (sort keys %hashes) {
        my $nameHash = md5_hex($_);
        my $codeHash = $hashes{$_};
        my $n1 = substr($nameHash, 0, 2);
        my $n2 = substr($nameHash, 2);
        my $hashFile = "$V{TMP}/.hash/$n1/${n2}_${codeHash}";
        generate($hashFile, [],
                 "\@$rm $V{TMP}/.hash/$n1/${n2}_* $_",
                 "\@$touch $hashFile");
        push_unique($rules{$_}{in}, $hashFile);
        rule_set_priority($hashFile, -100);
        rule_add_comment($hashFile, "Rule change marker for $_");
    }
}


##
##  Output
##

# Generate Makefile
sub output_makefile {
    # Implicit makefile stuff
    my $outfile = add_variable(OUTFILE => 'Makefile');
    generate_rule_hashes();    # first, because we don't want a rule hash for the next parts
    generate_rebuild_rule();   # needs $V{OUTFILE}
    generate_clean_rule();
    generate_phony_rule();     # last, to pick up phony targets created above

    verify();

    # Write it
    my $mf = $outfile;
    open MF, '>', "$mf.new" or die "$mf.new: $!\n";

    foreach (sort {$rules{$b}{pri} <=> $rules{$a}{pri} || $a cmp $b} keys %rules) {
        if (!$rules{$_}{did}) {
            $rules{$_}{did} = 1;
            print MF map {"# $_\n"} @{$rules{$_}{comment}};

            # The special-case for phony is required to correctly generate the inputs of .PHONY and can probably be dropped
            # if we move generation of the .PHONY rule out.
            my @in  = $rules{$_}{phony} ? @{$rules{$_}{in}} : grep {!/^-/} rule_get_inputs($_);
            my @out = grep {!/\.d$/} @{$rules{$_}{out}};
            if (length(join(' ', @in)) > 140) {
                print MF join(" \\\n  ", join(' ', @out, ":"), @in), "\n";
            } else {
                print MF join(' ', @out, ":", @in), "\n";
            }
            if (exists $rules{$_}{info}) {
                print MF "\t\@echo \"\t$rules{$_}{info}...\"\n";
                foreach (@{$rules{$_}{code}}) {
                    print MF "\t\@$_\n";
                }
            } else {
                foreach (@{$rules{$_}{code}}) {
                    print MF "\t$_\n";
                }
            }
            foreach (@{$rules{$_}{out}}) {
                print MF "-include $_\n"
                    if /\.d$/;
            }
            print MF "\n";
        }
    }
    close MF;
    rename "$mf.new", $mf
        or die "$mf: $!\n";
}

# Generate build.ninja
sub output_ninja_file {
    # No implicit stuff needed. Ninja has rule change detection built in, as well as 'clean'.
    my $outfile = add_variable(OUTFILE => 'build.ninja');
    verify();

    my $nf = $outfile;
    open NF, '>', "$nf.new" or die "$nf.new: $!\n";

    # Boilerplate
    print NF "rule generic\n";
    print NF "  command = \$command\n";
    print NF "\n";

    # Output rules
    foreach (sort {$rules{$b}{pri} <=> $rules{$a}{pri} || $a cmp $b} keys %rules) {
        if (!$rules{$_}{did}) {
            $rules{$_}{did} = 1;
            print NF map {"# $_\n"} @{$rules{$_}{comment}};

            my @in  = $rules{$_}{phony} ? @{$rules{$_}{in}} : grep {!/^-/} rule_get_inputs($_);
            my @dep = grep {/\.d$/} @{$rules{$_}{out}};
            my @out = grep {!/\.d$/} @{$rules{$_}{out}};

            # Transform commands
            my $code = join_commands(@{$rules{$_}{code}});

            # Phony?
            if ($code eq '' && $rules{$_}{phony}) {
                print NF "build ", join(' ', @out), ": phony ", join(' ', @in), "\n";
            } else {
                print NF "build ", join(' ', @out), ": generic ", join(' ', @in), "\n";
                print NF "  command = ", $code, "\n";
                print NF "  description = ", $rules{$_}{info}, "\n"
                    if exists $rules{$_}{info};
                print NF "  depfile = ", join(' ', @dep), "\n"
                    if @dep;
                print NF "\n";
            }
        }
    }
    print NF "default all\n";
    print NF "\n";
    close NF;
    rename "$nf.new", $nf
        or die "$nf: $!\n";
}

# Generate build.sh
sub output_script_file {
    my @todo = @_;
    if (!@todo) {
        die "Please specify targets to build for \"$0 scriptfile\"\n";
    }
    my $outfile = add_variable(OUTFILE => 'build.sh');

    verify();

    my $sf = $outfile;
    open SF, '>', "$sf.new" or die "$sf.new: $!\n";
    print SF "#\n";
    print SF "#  Build script for ", join(' ', @todo), "\n";
    print SF "#\n";
    print SF "#  Input files:\n";
    print SF map{"#   $_\n"} @input_files;
    print SF "#\n\n\n";

    while (@todo) {
        my $rule = $rules{$todo[0]};
        if (!$rule) {
            # Unknown input, assume it is a source file
            shift @todo;
        } elsif (!$rule->{did}) {
            # We didn't see this rule yet. Queue its dependencies and mark it pending.
            unshift @todo, grep {!$rules{$_}{did}} @{$rule->{in}};
            $rule->{did} = 1;
        } else {
            # Output rule
            my $old_pos = tell(SF);
            print SF map {"# $_\n"} @{$rule->{comment}};
            print SF "echo \"$rule->{info}\"\n"
                if exists $rule->{info};

            foreach (@{$rule->{code}}) {
                my $sep;
                if (s/^-//) {
                    $sep = "\n";
                } else {
                    $sep = " || exit 1\n";
                }
                s/^\@//;
                print SF $_, $sep;
            }
            print SF "\n"
                if tell(SF) != $old_pos;
            shift @todo;
        }
    }

    close SF;
    rename "$sf.new", $sf
        or die "$sf: $!\n";
}

##
##  Files
##

sub create_directory_for {
    foreach my $fn (@_) {
        if ($fn =~ m|^(.*)/|) {
            my $dir = $1;
            if (!-d $dir) {
                create_directory_for($dir);
                mkdir $dir, 0777 or die "$dir: error: cannot create directory: $!\n";
            }
        }
    }
}

# Update a file. If the file content does not change, does not touch the file.
sub file_update {
    my ($file, $content) = @_;
    create_directory_for($file);
    if (open my $in, '<', $file) {
        my $old_content = join('', <$in>);
        close $in;
        if ($old_content eq $content) {
            log_info("File $file is unchanged.");
            return;
        }
    }
    open my $out, '>', $file or die "$file: $!";
    print $out $content;
    close $out;
    log_info("Created $file.");
}

sub get_directory_content {
    my $dir = normalize_filename(shift);
    push @input_files, $dir
        unless grep {$_ eq $dir} @input_files;

    my @result;
    opendir my $dh, $dir or die "$dir: $!";
    foreach my $e (sort readdir $dh) {
        if ($e !~ /^\./ && $e ne 'CVS' && $e !~ /~$/) {
            push @result, normalize_filename($dir, $e);
        }
    }
    closedir $dh;
    @result;
}

sub get_directory_content_recursively {
    my $dir = normalize_filename(shift);
    my @result;
    foreach (get_directory_content($dir)) {
        push @result, $_;
        if (-d $_) {
            push @result, get_directory_content_recursively($_);
        }
    }
    @result;
}


##
##  File Names
##

sub split_filename {
    my $fn = shift;
    my $dir_part = ($fn =~ s|^(.*/)|| ? $1 : '');
    my $ext_part = ($fn =~ s|(\.[^.]+)$|| ? $1 : '');
    ($dir_part, $fn, $ext_part)
};

sub normalize_filename {
    my $fn = '.';
    foreach (@_) {
        if (m|^/|) {
            $fn = $_;
        } elsif ($fn =~ m|/$|) {
            $fn .= $_;
        } else {
            $fn .= '/'.$_;
        }
    }

    my @com;
    foreach (split m|/|, $fn) {
        if ($_ ne '.') {
            if ($_ eq '..' && @com && $com[-1] ne '..') {
                pop @com;
            } else {
                push @com, $_;
            }
        }
    }
    @com ? join('/', @com) : '.';
}

sub make_temp_filename {
    my $file = shift;
    my $in = get_variable('IN', @_);
    my $tmp = get_variable('TMP', @_);
    if (substr($file, 0, length($in)) eq $in) {
        # input/foo/bar --> tmp/foo/bar
        $tmp.substr($file, length($in));
    } elsif (substr($file, 0, length($tmp)) eq $tmp) {
        # tmp/foo/bar remains as is
        $file;
    } else {
        # whatever/x/y/z --> tmp/whatever/x/y/z
        $file =~ s|\.\.|__|g;
        normalize_filename($tmp, $file);
    }
}

##
##  Utilities
##

sub push_unique {
    my $list = shift;
    foreach my $v (@_) {
        push @$list, $v
            unless grep {$_ eq $v} @$list
    }
}

sub push_unique_last {
    my $list = shift;
    foreach my $v (@_) {
        @$list = grep {$_ ne $v} @$list;
        push @$list, $v;
    }
}

sub to_list {
    my $x = shift;
    return (!defined($x) ? () : ref($x) eq 'ARRAY' ? @$x : ($x));
}

sub to_prefix_list {
    my $prefix = shift;
    my @result;
    foreach (@_) {
        if (defined($_)) {
            push @result, map {normalize_filename($prefix, $_)} (ref($_) eq 'ARRAY' ? @$_ : split /\s+/, $_);
        }
    }
    @result;
}

sub is_subset {
    my ($small, $big) = @_;
    foreach my $e (@$small) {
        return 0 if !grep {$e eq $_} @$big;
    }
    return 1;
}

# Given a list of commands, join these to a single command.
sub join_commands {
    my @code;
    foreach (@_) {
        my $sep;
        if (s/^-//) {
            $sep = '; ';
        } else {
            $sep = ' && ';
        }
        s/^\@//;
        push @code, $_, $sep;
    }
    if (@code) {
        if ($code[-1] eq '; ') {
            push @code, 'true';
        } else {
            pop @code;
        }
    }
    join('', @code);
}

##
##  Variables
##

sub add_directory_variable {
    push_unique(\@dir_vars, @_);
}

sub add_variable {
    my $result;
    while (@_) {
        my $k = shift;
        my $v = shift;
        if (!exists $V{$k}) {
            $V{$k} = $v;
        }
        $result = $V{$k};
    }
    $result;
}

sub set_user_variable {
    my ($k, $v) = @_;
    $V{$k} = $v;
    $user_vars{$k} = $v;
}

sub set_variable {
    while (@_) {
        my $k = shift;
        my $v = shift;
        $V{$k} = $v;
    }
}

sub add_to_variable {
    my $k = shift;
    foreach (@_) {
        if (!exists $V{$k} || $V{$k} eq '') {
            $V{$k} = $_;
        } else {
            $V{$k} .= ' ' . $_;
        }
    }
}

sub get_variable {
    my $k = shift;
    my @c = grep {defined && !ref} map {$_->{$k}} \%V, @_;
    return @c ? $c[-1] : '';
}

sub get_variable_merge {
    my $k = shift;
    return join(' ', grep {defined && !ref} map {$_->{$k}} \%V, @_);
}

sub show_variables {
    foreach my $k (sort keys %V) {
        print "$k = $V{$k}\n";
        if (exists $user_vars{$k}) {
            if ($user_vars{$k} eq $V{$k}) {
                print "\t# user-set\n";
            } else {
                print "\t# user-set: $user_vars{$k})\n";
            }
        }
        if (grep {$_ eq $k} @dir_vars) {
            print "\t# directory\n";
        }
    }
}

sub _sanitize_variable_name {
    my $n = shift;
    $n =~ s/-/_/g;
    uc($n);
}

##
##  Directory handling
##

sub load_directory {
    foreach my $dir (@_) {
        # Validate
        if ($dir =~ m!^\.+(/|$)! || $dir =~ m!^/!) {
            die "Parameter to \"load_directory\" must be relative directory name.\n";
        }

        # Update directory variables
        my @old_dir_vars;
        foreach (@dir_vars) {
            push @old_dir_vars, $V{$_};
            $V{$_} = normalize_filename($V{$_}, $dir);
        }

        # Load file. IN has been updated at this place.
        load_file("$V{IN}/Rules.pl");

        # Restore directory variables
        foreach (@dir_vars) {
            $V{$_} = shift @old_dir_vars;
        }
    }
}

sub load_file {
    foreach my $mf (@_) {
        # Read the file
        $mf = normalize_filename($mf);
        open FILE, "< $mf" or die "$mf: $!\n";
        my $code = join("", <FILE>);
        close FILE;

        # Remember as input file
        push_unique(\@input_files, $mf);

        # Eval. Use eval, not do, because that evaluates the code in our scope.
        print "\tExecuting $mf...\n";
        eval $code;
        die "Sub-Makefile $mf failed: $@"
            if $@;
    }
}

sub load_module {
    foreach my $mod (@_) {
        my $ok = 0;
        foreach my $dir ($V{IN}, (split_filename($0))[0]) {
            my $mf = normalize_filename($dir, $mod);
            if (-e "$mf") {
                load_file("$mf");
                $ok = 1;
                last;
            }
        }
        die "Module $mod not found\n"
            if !$ok;
    }
}

sub load_variables {
    my $result = {};
    foreach my $file (@_) {
        open FILE, '<', $file or die "$file: $!\n";
        while (<FILE>) {
            chomp;
            while (s|\\$||) {
                $_ .= <FILE>;
                chomp;
            }
            if (/^(\S+)\s*=\s*(.*)/) {
                $result->{$1} = $2;
            } elsif (/^(\S+)\s*\+=\s*(.*)/) {
                $result->{$1} .= ' '.$2;
            }
        }
        close FILE;
        push_unique(\@input_files, $file);
    }
    $result;
}

sub verify {
    # Mark all files that we know are generated
    my %files;
    foreach (keys %rules) {
        foreach (@{$rules{$_}{out}}) {
            $files{$_} = 1
        }
    }

    # Verify that files we require are generated or present
    foreach my $r (sort keys %rules) {
        foreach my $f (@{$rules{$r}{in}}) {
            if (!$files{$f}) {
                if (! -e $f) {
                    print STDERR "$f: warning: file needed as input for $r, but does not exist.\n";
                }
                $files{$f} = 1;
            }
        }
    }
}
