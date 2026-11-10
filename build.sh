#!/bin/zsh
# Compile md2safari.swift into bin/md2pdf.
# The ABSOLUTE source path matters: the program locates its helper files
# (CSS, Lua filter, Python mask script) through #filePath.
set -e
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O "$PWD/md2safari.swift" -o "$PWD/bin/md2pdf"
echo "Built $PWD/bin/md2pdf"
