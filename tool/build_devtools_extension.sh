#!/bin/bash
# Builds the DevTools extension (devtools_extension/) into extension/devtools/
# and validates it. Run from the repository root after changing the extension.
set -euo pipefail
cd "$(dirname "$0")/.."

(cd devtools_extension && flutter pub get \
  && dart run devtools_extensions build_and_copy --source=. --dest=../extension/devtools)

# Debug symbols are never loaded at runtime; drop them to keep the package small.
find extension/devtools/build -name '*.symbols' -delete

(cd devtools_extension && dart run devtools_extensions validate --package=..)
du -sh extension/devtools/build
