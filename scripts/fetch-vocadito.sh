#!/usr/bin/env bash
# Downloads vocadito (58 MB, CC BY 4.0) into data/vocadito for `intonate-bench vocadito`.
# The recordings stay out of the repository: results/vocadito.json is what gets committed.
set -euo pipefail
cd "$(dirname "$0")/.."

url="https://zenodo.org/api/records/5578807/files/vocadito.zip/content"
expected="e0d6b99d3f9c594afe5ae5c4d7bdacebe569e53b809e90b89d1c771c4f9990e3"

mkdir -p data
curl --fail --location --output data/vocadito.zip "$url"
actual=$(shasum -a 256 data/vocadito.zip | cut -d' ' -f1)
if [[ "$actual" != "$expected" ]]; then
    echo "checksum mismatch: got $actual" >&2
    exit 1
fi
unzip -q -o data/vocadito.zip -d data/vocadito -x '__MACOSX/*'
echo "data/vocadito is ready"
