#
#  Compiling C
#
#  Compiles a C program and runs it.
#  Exercises creation of compilation rules and variable substitution.
#

. ./lib.sh "$@"

cat >Rules.pl <<'EOF'
load_module('Compiler.pl');
my $exe = compile_executable(t => 't.c');
generate(all => $exe);
generate(out => $exe, './$< >$@');
EOF
cat >t.c <<EOF
#include <stdio.h>
int main()
{
  puts("hello, world");
  return 0;
}
EOF

perl $SCRIPT
make
must_fail test -f out
must_fail test -f all

make out
echo "hello, world" | diff - out
