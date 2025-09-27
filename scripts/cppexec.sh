#!/usr/bin/env bash
nix develop -c bash -c 
dir=$(dirname "$0")
cd "$dir"
cpp_files=(*.cpp)
case ${#cpp_files[@]} in
  0) echo "No .cpp files found"; exit 1 ;;
  1) file=${cpp_files[0]} ;;
  *)
    echo "Multiple .cpp files:"
    for i in "${!cpp_files[@]}"; do
      echo "$((i+1))) ${cpp_files[i]}"
    done
    read -p "Select file to compile: " idx
    file=${cpp_files[$((idx-1))]}
    ;;
esac
out=${file%.cpp}
g++ "$file" -o "$out"

