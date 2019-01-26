#
#  Compiling C++
#
#  Compiles a C++ program with different options.
#  Exercises regeneration of build files.
#

. ./lib.sh "$@"

cat >Rules.pl <<'EOF'
load_module('Compiler.pl');
set_variable(CXXFLAGS => '-DFOO=42');
my $exe = compile_executable(t => 't.cpp');
generate(all => $exe);
generate(out => $exe, './$< >$@');
EOF
cat >t.cpp <<EOF
#include <iostream>
int main()
{
  std::cout << FOO << "\n";
}
EOF

perl $SCRIPT

# Generate and verify output
make out
echo 42 | diff - out

# Change build script. Must be applied without explicitly invoking Make.pl again.
cat >Rules.pl <<'EOF'
load_module('Compiler.pl');
set_variable(CXXFLAGS => '-DFOO=23');
my $exe = compile_executable(t => 't.cpp');
generate(all => $exe);
generate(out => $exe, './$< >$@');
EOF

make out
echo 23 | diff - out
