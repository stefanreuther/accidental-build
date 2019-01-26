##
##  Test boilerplate
##

must_fail() {
  if "$@"; then
    echo "'$@' succeeded but shouldn't" >&2
    exit 1
  fi
}


# Testee directory
ROOT="$(pwd)/.."
SCRIPT="$ROOT/Make.pl"
if ! test -e "$SCRIPT"; then
  echo "$SCRIPT: not found" >&2
  exit 1
fi

# Work directory is given as parameter
if test -z "$1"; then
  echo "Missing work directory." >&2
  exit 1
fi

# Set up for test
set -e
cd "$1"
