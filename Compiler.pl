add_variable(CXX => 'g++');
add_variable(CXXFLAGS => "-I$V{IN}");
add_variable(PERL => 'perl');
add_variable(LDFLAGS => '');
add_variable(AR => 'ar');
add_variable(RANLIB => ':');
add_variable(RUN => '');
add_variable(EXE_SUFFIX => '');


sub compile_file {
    my ($file, $opts) = @_;
    my @result;
    my ($dir, $stem, $ext) = split_filename($file);
    if ($ext eq '.c' || $ext eq '.cpp') {
        # C/C++
        my $uniq = '';
        while (1) {
            my $base = make_temp_filename("$dir$stem$uniq");
            my $o = "$base.o";
            my $d = "$base.d";
            my $cxx = get_variable('CXX', $opts, $opts->{$file});
            my $cxxflags = get_variable_merge('CXXFLAGS', $opts, $opts->{$file});
            if (generate_unique([$d, $o], $file, "$cxx $cxxflags -c $file -o $o -MMD -MP")) {
                rule_add_info($o, "Compiling $file");
                push @result, $o;

                # FIXME: add rule for assembly (*.s):
                # generate_unique("$base.s", $file, "$cxx $cxxflags -S $file -o $base.s");
                last;
            }
            ++$uniq;
        }
    } elsif ($ext eq '.h' || $ext eq '.hpp') {
        # Ignore
    } elsif ($ext eq '.o') {
        # Keep
        push @result, $file;
    } else {
        die "I do not know how to compile \"$file\"\n";
    }
    @result;
}

sub compile_static_library {
    my ($stem, $objs, $libs, $opts) = @_;

    my @objs = map {compile_file($_, $opts)} to_list($objs);

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
            push @in, $_;
        } else {
            my $uniq_fn = normalize_filename($V{TMP}, ".lib/$out_base/$stem$uniq$ext");
            generate_copy($uniq_fn, $_);
            rule_add_comment($uniq_fn, "Unique basename for $_ for archiving into $out");
            push @in, $uniq_fn;
        }
    }
    generate_unique($out, [@in], "$V{AR} cr $out ".join(' ', @in), "$V{RANLIB} $out");
    rule_add_info($out, "Archiving $out");

    if ($stem ne $out) {
        generate($stem, $out);
        rule_set_phony($stem);
    }
    rule_add_link($stem, to_list($libs));
    $out;
}




sub compile_executable {
    my ($exe, $src, $lib, $opts) = @_;
    my @objs = map {compile_file($_, $opts)} to_list($src);
    my @libs = to_list($lib);
    my $suffix = add_variable('EXE_SUFFIX', '');
    my $out = normalize_filename("$V{OUT}", "$exe$suffix");

    my @lib_options = rule_get_link_inputs(@libs);

    my $ldflags = get_variable_merge('LDFLAGS', $opts);
    my $libs = get_variable_merge('LIBS', $opts);

    generate_unique($out, [@objs, grep {!/^-/} @libs], "$V{CXX} $ldflags -o $out ".join(' ', @objs, @lib_options, $libs));
    rule_add_info($out, "Linking $out");

    generate('all', $out);

    if ($out ne $exe) {
        generate($exe, $out);
        rule_set_phony($exe);
    }

    $out;
}

sub compile_add_prebuilt_library {
    my ($name, $file, $deps) = @_;

    # Linker rule:
    #     <stem> : <file.a>
    #        // link = additional linker rules or -l options

    generate($name, $file);
    rule_set_phony($name);
    rule_add_link($name, to_list($deps));
}
