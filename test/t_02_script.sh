#
#  Basic functionality test
#
#  Create a simple shell script that copies a file, and check that it works.
#

. ./lib.sh "$@"

cat >Rules.pl <<EOF
generate_copy('out/a.txt', 'a.txt');
generate('all', 'out/a.txt');
EOF
cat >a.txt <<EOF
Sample
EOF

perl $SCRIPT scriptfile all
sh build.sh

diff out/a.txt a.txt
