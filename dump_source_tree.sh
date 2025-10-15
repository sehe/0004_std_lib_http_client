dump_source_tree() {
  local root="${1:-.}"  # Default to current dir if none provided
  find "$root" \
    \( -type d \( -name "build_*" -o -name "venv*" -o -name ".venv*" -o -name "cmake-build*" -o -name "htmlcov" -o -name ".idea" -o -name "*pycache*" -o -name ".pytest_cache" -o -name "target" -o -name "build" \) -prune \) -o \
    \( -type f \( -name "*.c" -o -name "*.cpp" -o -name "*.h" -o -name "CMakeLists*" -o -name "*.py" -o -name "*.json" -o -name "*.cfg" -o -name "*.toml" -o -name ".gitignore" -o -name "*.html" -o -name "*.hpp" -o -name "*.rs" -o -name "*.sh" \) \) \
    -print | while read -r file; do
      echo "$file"
      echo "\`\`\`"
      cat "$file"
      echo
      echo "\`\`\`"
      echo -e "\n\n"
  done
}

dump_source_tree