#!/bin/sh
# lint-staged task for native sources. Inside lint-staged the working tree
# equals the staged content, so `git clang-format HEAD` formats exactly the
# staged hunks — never the untouched remainder of a legacy file — and
# lint-staged re-stages whatever this modifies.
#
# git-clang-format exits 1 to mean "files were reformatted", which is success
# here; real errors die() with exit 2 and still fail the commit.
git clang-format HEAD -- "$@"
status=$?
if [ "$status" -le 1 ]; then
  exit 0
fi
exit "$status"
