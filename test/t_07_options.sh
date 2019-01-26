#
#  Compiling C++ with different options
#
#  Compiles a C++ program from multiple source files with different options.
#  Exercises selection of object file names.
#

. ./lib.sh "$@"

cat >Rules.pl <<'EOF'
load_module('Compiler.pl');
generate(out => compile_executable(t => ['main.cpp',
                       compile_file('lib.cpp', {CXXFLAGS => '-DFUN=one -DVAL=1'}),
                       compile_file('lib.cpp', {CXXFLAGS => '-DFUN=two -DVAL=2'})]),
         './$< >$@');
EOF
cat >main.cpp <<EOF
#include <iostream>
extern int one(), two();
int main()
{
  std::cout << one() << " " << two() << "\n";
}
EOF
cat >lib.cpp <<EOF
int FUN()
{
  return VAL;
}
EOF

perl $SCRIPT
make out
echo "1 2" | diff - out
