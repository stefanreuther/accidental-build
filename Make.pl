#!/usr/bin/perl -w
use strict;
use Digest::MD5 qw(md5_hex);

# Rules
#    in : [str]          input files
#    out : [str]         output files
#    code : [str]        commands
#    dir : int           is this a directory?
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

# Main
my %V = (
    OUT => '.',
    IN => '.',
    TMP => 'tmp',
    INFILE => 'Rules.pl',
    OUTFILE => 'Makefile'
);
my %user_vars;

add_directory_variable(qw(OUT IN TMP));

# Parse parameters
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
        die "$0: unrecognized parameter \"$_\"\n";
    }
}
generate('all', []);
rule_set_phony('all');
rule_set_priority('all', 100);

load_file("$V{IN}/$V{INFILE}");


##
##  General Infrastructure
##

# Create a directory.
#    generate_directory($x)
# Makes a rule to create the directory $x.
# Parents will also be created.
sub generate_directory {
    my $dir = shift;
    if (exists($rules{$dir})) {
        if (!$rules{$dir}{dir}) {
            die "Rule type conflict.\n".
                "Requested directory: ".$dir."\n".
                "Rule already describes a file.\n";
        }
    } else {
        my $mkdir = add_variable('MKDIR', 'mkdir');
        my $touch = add_variable('TOUCH', 'touch');
        my $mark = "$dir/.mark";
        my $rule = { in => [], out => [$mark], code => ["-\@$mkdir -p $dir", "\@$touch $mark"], dir => 1, pri => -99, precious => 1 };
        $rules{$mark} = $rule;
        if ($dir =~ m|^(.*)/|) {
            my $p = $1;
            push_unique($rule->{in}, "$p/.mark");
            generate_directory($p);
        }
    }
}

# Generate files.
#    generate($out, $in, $cmds)
# This is the main function to generate a Makefile rule.
# $out and $in are either strings (single file) or list references (multiple files).
# This will generate a rule that creates $out from $in using the given commands $cmds.
# If a rule with the same outputs already exists, it is extended: additional inputs added,
# additional commands added.
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
        if ($rule->{dir}) {
            die "Rule type conflict.\n".
                "Requested files: ".join(' ', @out)."\n".
                "Rule already describes a directory.\n";
        }
    } else {
        $rule = { in => [@in], out => [@out], code => [@code], dir => 0, pri => $pri };
        foreach (@out) {
            $rules{$_} = $rule;
        }
    }

    # Add directories
    foreach (@out) {
        if (m|^(.*)/| && !m!^(\.\./|/)!) {
            my $dir = $1;
            push_unique($rule->{in}, "$dir/.mark");
            generate_directory($dir);
        }
    }
}

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
                return 0;
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

sub generate_copy {
    my ($out, $in) = @_;
    my $cp = add_variable('CP', 'cp');
    generate($out, $in, "\@$cp $in $out");
}

# Set priority of a rule.
#    rule_set_priority($rule, $pri)
# High priorities place the rule at the beginning of the Makefile, low priorities at the end.
sub rule_set_priority {
    my ($rule, $pri) = @_;
    _rule_get($rule)->{pri} = $pri;
}

# Add comment to a rule.
#    rule_add_comment($rule, $text...)
sub rule_add_comment {
    my $rule = shift;
    push @{_rule_get($rule)->{comment}}, @_;
}

sub rule_add_info {
    my ($rule, $info) = @_;
    _rule_get($rule)->{info} = $info;
}

sub rule_set_phony {
    foreach (@_) {
        _rule_get($_)->{phony} = 1;
    }
}

sub rule_set_precious {
    foreach (@_) {
        _rule_get($_)->{precious} = 1;
    }
}

sub rule_add_link {
    my $rule = shift;
    push @{_rule_get($rule)->{link}}, @_;
}

sub rule_get_inputs {
    my @todo = map {$rules{$_} && $rules{$_}{in} ? @{$rules{$_}{in}} : ()} @_;
    my @result;
    my %did;
    while (@todo) {
        my $item = shift @todo;
        if ($item =~ /^-/) {
            # Option
        } elsif (!$rules{$item} || !$rules{$item}{link}) {
            # Regular rule, just output
            push_unique(\@result, $item);
        } else {
            # Library rule. Map to actual inputs
            $did{$item} = 1;
            push_unique(\@result, @{$rules{$item}{in}});
            push @todo, grep {!$did{$_}++} @{$rules{$item}{link}};
        }
    }
    @result;
}

sub rule_get_link_inputs {
    my @todo = @_;
    my @result;
    my %did;
    while (@todo) {
        my $item = shift @todo;
        if ($item =~ /^-/) {
            # Option
            push @result, $item;
        } elsif (!$rules{$item} || !$rules{$item}{link}) {
            # Regular rule, just output
            push_unique(\@result, $item);
        } else {
            # Library rule. Map to actual inputs
            $did{$item} = 1;
            push_unique(\@result, @{$rules{$item}{in}});
            push @todo, grep {!$did{$_}++} @{$rules{$item}{link}};
        }
    }
    @result;
}

# Make an auto-rebuild rule for a directory.
#   rule_rebuild_directory($dir)
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

    # Generate hash rule
    my $child_hash = md5_hex(join("\n", sort @children));
    my $name_hash = md5_hex($mark);
    my $n1 = substr($name_hash, 0, 2);
    my $n2 = substr($name_hash, 2);
    my $hash_file = "$V{TMP}/.hash/$n1/${n2}_${child_hash}";
    my $rm = add_variable('RM', 'rm -f');
    generate($hash_file, [],
             "\@$rm $V{TMP}/.hash/$n1/${n2}_*",
             "\@$rm -r $dir",
             "\@touch $hash_file");
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

# Generate rebuild rule.
#   generate_rebuild_rule()
# The rule will automatically rebuild the Makefile if any input file changed.
sub generate_rebuild_rule {
    my $mf = normalize_filename("$V{OUT}/$V{OUTFILE}");
    add_variable('PERL', 'perl');
    generate($mf, [@input_files, $0],
             join(' ', 
                  "$V{PERL} $0",
                  map {"$_=\"$user_vars{$_}\""} sort keys %user_vars)); # FIXME: quoting
    rule_add_comment($mf, 'Automatically regenerate build file');
    rule_add_info($mf, "Rebuilding $mf");
    rule_set_precious($mf);

    # Add a blank 'foo :' rule for each input file (same as 'gcc -MP' would do).
    # This way, a rebuild will work properly if an include file has been moved.
    # Rules must be marked precious so generate_clean_rule() will not delete them.
    foreach (@input_files, $0) {
        generate($_);
        rule_set_precious($_);
    }
}

# Generate .PHONY rule.
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

# Generate clean rule.
#   generate_clean_rule()
# This rule will remove all outputs not marked rule_set_phony() or rule_set_precious().
sub generate_clean_rule {
    my @files;
    foreach (sort keys %rules) {
        push_unique(\@files, @{$rules{$_}{out}})
            unless $rules{$_}{precious} || $rules{$_}{phony};
    }

    my @cmds;
    my $line = '';
    my $n = 0;
    add_variable('RM', 'rm -f');
    foreach (@files) {
        ++$n;
        $line .= ' '.$_;
        if (length($line) > 120) {
            push @cmds, $V{RM}.$line;
            $line = '';
            if (@cmds % 100 == 0) {
                push @cmds, sprintf ("echo \"\tCleaning up (%d%%)...\"", 100 * $n / scalar(@files));
            }
        }
    }
    push @cmds, $V{RM}.$line
        if $line ne '';

    generate('clean', [], @cmds);
    rule_set_phony('clean');
    rule_add_info('clean', 'Cleaning up');
}

# Generate rule hashes.
#    generate_rule_hashes()
# Builds makefile rules that will make rules rerun if the rule content changes,
# even if the input files are unchanged.
sub generate_rule_hashes {
    # The idea is to generate a marker file "xx_yy", where "xx" identifies the file in question, and "yy" identifies the rule content.
    # If rule content changes, removing "xx_*" will remove old rule hashes.
    add_variable('RM', 'rm -f');

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
        generate($hashFile, [], "\@$V{RM} $V{TMP}/.hash/$n1/${n2}_* $_", "\@touch $hashFile");
        push_unique($rules{$_}{in}, $hashFile);
        rule_set_priority($hashFile, -100);
        rule_add_comment($hashFile, "Rule change marker for $_");
    }
}


##
##  Output
##

# Generate output
sub output_makefile {
    # Implicit makefile stuff
    generate_rule_hashes();    # first, because we don't want a rule hash for the next parts
    generate_rebuild_rule();
    generate_clean_rule();
    generate_phony_rule();     # last, to pick up phony targets created above

    verify();

    # Write it
    output_makefile_only("$V{OUT}/$V{OUTFILE}");
}

sub output_makefile_only {
    my $mf = shift;
    open MF, '>', "$mf.new" or die "$mf.new: $!\n";

    foreach (sort {$rules{$b}{pri} <=> $rules{$a}{pri} || $a cmp $b} keys %rules) {
        if (!$rules{$_}{did}) {
            $rules{$_}{did} = 1;
            print MF map {"# $_\n"} @{$rules{$_}{comment}};

            my @in = $rules{$_}{phony} ? @{$rules{$_}{in}} : rule_get_inputs($_);
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
    join('/', @com);
}

sub make_temp_filename {
    my $file = shift;
    if (substr($file, 0, length($V{IN})) eq $V{IN}) {
        # input/foo/bar --> tmp/foo/bar
        $V{TMP}.substr($file, length($V{IN}));
    } elsif (substr($file, 0, length($V{TMP})) eq $V{TMP}) {
        # tmp/foo/bar remains as is
        $file;
    } else {
        # whatever/x/y/z --> tmp/whatever/x/y/z
        $file =~ s|\.\.|__|g;
        normalize_filename($V{TMP}, $file);
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

sub to_list {
    my $x = shift;
    return (!defined($x) ? () : ref($x) eq 'ARRAY' ? @$x : ($x));
}

sub to_prefix_list {
    my ($prefix, $list) = @_;
    return (!defined($list)
            ? ()
            : map {"$prefix/$_"} (ref($list) eq 'ARRAY' ? @$list : split /\s+/, $list));
}

sub is_subset {
    my ($small, $big) = @_;
    foreach my $e (@$small) {
        return 0 if !grep {$e eq $_} @$big;
    }
    return 1;
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

sub get_variable {
    my $k = shift;
    my @c = grep {defined && !ref} map {$_->{$k}} \%V, @_;
    return @c ? $c[-1] : '';
}

sub get_variable_merge {
    my $k = shift;
    return join(' ', grep {defined && !ref} map {$_->{$k}} \%V, @_);
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
            $V{$_} .= "/$dir";
        }

        load_file("$dir/Make.pl");

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
