#
#  Compiling C++
#
#  Compiles a C++ program.
#  Exercises rebuild.
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

# Generate and verify output
make out
echo "hello, world" | diff - out

# Change program
cat >t.cpp <<EOF
broken
EOF
must_fail make out

# Change program again
cat >t.cpp <<EOF
#include <iostream>
int main()
{
  std::cout << "hello, new world\n";
}
EOF

make out
echo "hello, new world" | diff - out
