#
#  Basic functionality test
#
#  Create a simple makefile that copies a file, and check that it works.
#

. ./lib.sh "$@"

cat >Rules.pl <<EOF
generate_copy('out/a.txt', 'a.txt');
generate('all', 'out/a.txt');
EOF
cat >a.txt <<EOF
Sample
EOF

perl $SCRIPT
make

diff out/a.txt a.txt
