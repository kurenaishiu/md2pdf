#!/bin/zsh
# Compile md2safari.swift into bin/md2pdf.
# The binary finds its helper files via its own location (bin/..), so a relative path is fine.
set -e
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O md2safari.swift -o bin/md2pdf
echo "Built $PWD/bin/md2pdf"
