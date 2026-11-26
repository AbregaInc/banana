#!/bin/sh
# Usage: run.sh MAC_RELEASE_DERIVED_DATA NEW_RESULT_JSON
set -eu
root=$(git rev-parse --show-toplevel)
products="$1/Build/Products/Release"
sqlite="$1/SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git -C "$root" show f987bd34:Banana/Model/NoteRepository.swift | sed 's/NoteRepository/ReferenceRepository/g' > "$tmp/ReferenceRepository.swift"
"$root/tools/agents/xcode-lock.sh" xcrun swiftc -O -D BANANA_MODULE_NOTES \
    -I "$products" -I "$sqlite" "$products/GRDB.o" -lsqlite3 \
    "$root"/Banana/Model/LiveFilter.swift "$root"/Banana/Model/VoiceNote.swift \
    "$root"/Shared/JSONRecordStream.swift "$root"/Banana/Model/NoteRepository.swift \
    "$tmp/ReferenceRepository.swift" "$root/tools/search-eval/notes-pages/main.swift" -o "$tmp/probe"
"$tmp/probe" "$2"
