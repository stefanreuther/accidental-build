#
#  Compiling C++
#
#  Compiles a C++ program and runs it.
#  Exercises creation of compilation rules and variable substitution.
#

. ./lib.sh "$@"

cat >Rules.pl <<'EOF'
load_module('Compiler.pl');
my $exe = compile_executable(t => 't.cpp');
generate(all => $exe);
generate(out => $exe, './$< >$@');
EOF
cat >t.cpp <<EOF
#include <iostream>
int main()
{
  std::cout << "hello, world\n";
}
EOF

perl $SCRIPT
make
must_fail test -f out
must_fail test -f all

make out
echo "hello, world" | diff - out
