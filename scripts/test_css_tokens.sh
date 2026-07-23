#!/usr/bin/env bash
# CSS Design Token Validator
# Tests for hardcoded values in all theme CSS files
# Usage: ./scripts/test_css_tokens.sh [theme_name]
#   Without arguments: checks all themes
#   With theme_name: checks only that theme

set -e

THEMES_BASE="assets/css/scheduling/themes"
FAILED=0
TOTAL_VIOLATIONS=0
THEMES_TESTED=0
THEMES_FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🔍 CSS Design Token Validator"
echo "================================"
echo ""

# Allowed hardcoded values (intentional design decisions)
ALLOWED_VALUES=(
  "520px"  # .scheduling-box width
  "56px"   # success-badge mobile
  "64px"   # success-badge desktop
  "40px"   # success-badge short-viewport (max-height: 600px)
  "32px"   # success-badge extra-short-viewport (max-height: 400px)
  "28px"   # success-icon mobile
  "96vw"   # max-width percentage
  "100%"   # percentage values
  "100vh"  # viewport units
  "100dvh" # dynamic viewport
  "50vh"   # viewport units
  "60vh"   # viewport units
  "-webkit-fill-available" # browser-specific
  "0"      # zero values
  "1"      # unitless values for flex, grid, aspect-ratio
  "50%"    # percentage for centering
  "150%"   # saturation values
  "0.5rem" # Special case for word-spacing or very small values in animations
)

# Strip the "path:lineno:" prefix that stripped_css_lines prepends, leaving only
# the CSS declaration text. Paths here never contain ':' and line numbers are
# digits, so dropping the first two colon-delimited fields is safe. Keeping the
# allowed-value check off the prefix is essential: matching against the prefix let
# any line whose NUMBER contained an allow-listed digit (e.g. "0"/"1") silently
# exempt a real violation.
declaration_of() {
  local rest="${1#*:}" # drop "path:"
  printf '%s' "${rest#*:}" # drop "lineno:"
}

# True if a declaration is an intentional exception: it routes through a token or
# calc(), or ALL of its raw length values EXACTLY match allow-listed design
# constants. A single non-allow-listed value causes the declaration to be flagged.
# Exact matching (not substring) means "10px" is no longer exempted just because
# "1" is allow-listed for unitless flex values.
is_exception_decl() {
  local decl="$1"
  [[ "$decl" == *"var("* || "$decl" == *"calc("* ]] && return 0
  local values value found_any=0
  values=$(printf '%s' "$decl" | grep -oE '\-?[0-9]+(\.[0-9]+)?(px|rem|em|%)')
  [ -z "$values" ] && return 1
  while IFS= read -r value; do
    [ -z "$value" ] && continue
    found_any=1
    local matched=0
    for allowed in "${ALLOWED_VALUES[@]}"; do
      [[ "$value" == "$allowed" ]] && matched=1 && break
    done
    [ "$matched" -eq 0 ] && return 1
  done <<< "$values"
  [ "$found_any" -eq 1 ] && return 0
  return 1
}

# Emit every CSS line in a theme as "file:lineno:content", with the contents of
# /* ... */ comments blanked out (replaced by spaces) so hardcoded values that
# only appear inside documentation comments are never flagged. Line numbers are
# preserved because only non-newline characters inside comments are removed, so
# reported locations stay accurate.
stripped_css_lines() {
  local theme_path="$1"
  find "$theme_path" -name "*.css" -type f | sort | while IFS= read -r f; do
    perl -0777 -pe 's{/\*.*?\*/}{ $x = $&; $x =~ tr/\n//cd; $x }ges' "$f" \
      | awk -v fn="$f" '{ print fn ":" NR ":" $0 }'
  done
}

# Function to test for hardcoded spacing values.
# Scope: the spacing SCALE governs padding / margin / gap. Positioning insets
# (top/right/bottom/left) are geometry, not spacing — they are frequently
# negative and proportional to a sibling's size (e.g. a corner badge offset that
# scales with its avatar), so they are intentionally raw and are NOT checked here.
test_hardcoded_spacing() {
  local theme_path="$1"
  echo "📏 Testing for hardcoded spacing values..."

  local violations=$(stripped_css_lines "$theme_path" | grep \
    -E '\s(padding|margin|gap):\s*-?[0-9]+(\.[0-9]+)?(px|rem|em)' \
    2>/dev/null || true)

  if [ -n "$violations" ]; then
    local filtered_violations=""
    while IFS= read -r line; do
      if ! is_exception_decl "$(declaration_of "$line")"; then
        filtered_violations+="$line"$'\n'
      fi
    done <<< "$violations"

    if [ -n "$filtered_violations" ]; then
      echo -e "${RED}✗ Found hardcoded spacing values:${NC}"
      echo "$filtered_violations"
      FAILED=1
      TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + $(echo "$filtered_violations" | grep -c "^" || echo 0)))
    else
      echo -e "${GREEN}✓ No hardcoded spacing values found${NC}"
    fi
  else
    echo -e "${GREEN}✓ No hardcoded spacing values found${NC}"
  fi
  echo ""
}

# Function to test for hardcoded border widths
test_hardcoded_borders() {
  local theme_path="$1"
  echo "🔲 Testing for hardcoded border widths..."

  local violations=$(stripped_css_lines "$theme_path" | grep \
    -E '\s(border|border-(top|bottom|left|right|width)):\s*[0-9]+px' \
    2>/dev/null || true)

  if [ -n "$violations" ]; then
    # Filter out already tokenized borders
    local filtered=$(echo "$violations" | grep -v "var(--border-width" || true)

    if [ -n "$filtered" ]; then
      echo -e "${RED}✗ Found hardcoded border widths:${NC}"
      echo "$filtered"
      FAILED=1
      TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + $(echo "$filtered" | grep -c "^" || echo 0)))
    else
      echo -e "${GREEN}✓ No hardcoded border widths found${NC}"
    fi
  else
    echo -e "${GREEN}✓ No hardcoded border widths found${NC}"
  fi
  echo ""
}

# Function to test for hardcoded dimensions
test_hardcoded_dimensions() {
  local theme_path="$1"
  echo "📐 Testing for hardcoded width/height values..."

  local violations=$(stripped_css_lines "$theme_path" | grep \
    -E '\s(width|height|min-width|max-width|min-height|max-height):\s*[0-9]+px' \
    2>/dev/null || true)

  if [ -n "$violations" ]; then
    local filtered_violations=""
    while IFS= read -r line; do
      if ! is_exception_decl "$(declaration_of "$line")"; then
        filtered_violations+="$line"$'\n'
      fi
    done <<< "$violations"

    if [ -n "$filtered_violations" ]; then
      echo -e "${YELLOW}⚠ Found hardcoded dimensions (review if intentional):${NC}"
      echo "$filtered_violations"
      # Don't fail on dimensions, just warn
      TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + $(echo "$filtered_violations" | grep -c "^" || echo 0)))
    else
      echo -e "${GREEN}✓ No hardcoded dimensions found${NC}"
    fi
  else
    echo -e "${GREEN}✓ No hardcoded dimensions found${NC}"
  fi
  echo ""
}

# Function to test for consistent token usage
test_token_usage() {
  local theme_path="$1"
  echo "🎨 Testing for design token availability..."

  # Check if all required tokens are defined
  local tokens_file="$theme_path/modules/variables.css"

  # Skip if no variables file exists yet
  if [ ! -f "$tokens_file" ]; then
    echo -e "${YELLOW}⚠ No variables.css found - skipping token checks${NC}"
    echo ""
    return 0
  fi

  local required_tokens=(
    "--space-3xs"
    "--space-2xs"
    "--space-xs"
    "--space-sm"
    "--space-md"
    "--space-lg"
    "--space-xl"
    "--space-2xl"
    "--border-width-thin"
    "--border-width-medium"
    "--border-width-thick"
    "--flag-height"
  )

  local missing_tokens=0
  for token in "${required_tokens[@]}"; do
    if ! grep -qF -- "$token:" "$tokens_file"; then
      echo -e "${RED}✗ Missing token: $token${NC}"
      missing_tokens=$((missing_tokens + 1))
      FAILED=1
    fi
  done

  if [ $missing_tokens -eq 0 ]; then
    echo -e "${GREEN}✓ All required design tokens are defined${NC}"
  fi
  echo ""
}

# Function to check for duplicate token definitions
test_duplicate_tokens() {
  local theme_path="$1"
  echo "🔄 Testing for duplicate token definitions..."

  local tokens_file="$theme_path/modules/variables.css"

  # Skip if no variables file exists yet
  if [ ! -f "$tokens_file" ]; then
    echo -e "${YELLOW}⚠ No variables.css found - skipping duplicate checks${NC}"
    echo ""
    return 0
  fi

  local duplicates=$(grep -oP '^\s*--[\w-]+(?=:)' "$tokens_file" | sort | uniq -d)

  if [ -n "$duplicates" ]; then
    echo -e "${RED}✗ Found duplicate token definitions:${NC}"
    echo "$duplicates"
    FAILED=1
    TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + $(echo "$duplicates" | grep -c "^" || echo 0)))
  else
    echo -e "${GREEN}✓ No duplicate token definitions found${NC}"
  fi
  echo ""
}

# Function to test module import integrity: every module imported by theme.css
# must exist, and every module file must be imported (no orphans). This guards
# the self-contained per-module structure — a forgotten @import silently drops a
# component's styles, and an orphan file is dead weight.
test_module_imports() {
  local theme_path="$1"
  echo "📦 Testing module import integrity..."

  local theme_css="$theme_path/theme.css"
  if [ ! -f "$theme_css" ] || [ ! -d "$theme_path/modules" ]; then
    echo -e "${YELLOW}⚠ No theme.css/modules - skipping import checks${NC}"
    echo ""
    return 0
  fi

  local imported present
  imported=$(grep -oE 'modules/[A-Za-z0-9_-]+\.css' "$theme_css" | sed 's#modules/##' | sort -u)
  present=$(find "$theme_path/modules" -maxdepth 1 -name "*.css" -type f -exec basename {} \; | sort -u)

  local missing orphan issues=0
  missing=$(comm -23 <(echo "$imported") <(echo "$present"))
  orphan=$(comm -13 <(echo "$imported") <(echo "$present"))

  if [ -n "$missing" ]; then
    echo -e "${RED}✗ Imported but missing module file(s):${NC}"
    echo "$missing"
    FAILED=1
    issues=$((issues + $(echo "$missing" | grep -c "^")))
  fi
  if [ -n "$orphan" ]; then
    echo -e "${RED}✗ Module file(s) present but never imported by theme.css:${NC}"
    echo "$orphan"
    FAILED=1
    issues=$((issues + $(echo "$orphan" | grep -c "^")))
  fi

  if [ "$issues" -eq 0 ]; then
    echo -e "${GREEN}✓ All modules imported and present${NC}"
  else
    TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + issues))
  fi
  echo ""
}

# Function to test @keyframes integrity:
#   • used-but-undefined: an `animation:` references a keyframe that no theme or
#     shared stylesheet defines (a broken animation — the failure mode that bites
#     when dead CSS is removed but a live reference is missed).
#   • defined-but-unused: a keyframe defined in this theme is never referenced
#     (dead code — surfaced as a warning).
# Comment-stripped content is used so commented-out rules never count.
test_keyframes() {
  local theme_path="$1"
  echo "🎞  Testing @keyframes integrity..."

  # Shared booking CSS (reset/layout/utilities) sits beside the themes dir and is
  # @imported by every theme.css — its keyframes (e.g. `spin`) count as defined.
  local shared="$(dirname "$THEMES_BASE")/shared"

  # Keyframes defined anywhere the theme can see (its own modules + shared).
  local defined_all theme_defined referenced
  defined_all=$( { stripped_css_lines "$theme_path"; [ -d "$shared" ] && stripped_css_lines "$shared"; } \
    | grep -oE '@keyframes[[:space:]]+[A-Za-z][A-Za-z0-9_-]*' \
    | sed -E 's/@keyframes[[:space:]]+//' | sort -u)

  # Keyframes defined by THIS theme (orphan check is scoped to the theme; shared
  # keyframes may legitimately be used only by another theme).
  theme_defined=$(stripped_css_lines "$theme_path" \
    | grep -oE '@keyframes[[:space:]]+[A-Za-z][A-Za-z0-9_-]*' \
    | sed -E 's/@keyframes[[:space:]]+//' | sort -u)

  # Names referenced by animation / animation-name. The shorthand can place the
  # keyframe name anywhere in its value (e.g. "animation: 1s spin" has the name
  # after the duration). Extract every identifier token from each animation value,
  # then keep only those that match a defined keyframe name — that naturally
  # excludes timing functions, keywords, and other non-name tokens.
  referenced=$(stripped_css_lines "$theme_path" \
    | grep -oE '(animation|animation-name):[[:space:]]*[^;{]+' \
    | sed -E 's/^(animation|animation-name):[[:space:]]*//' \
    | grep -oE '[A-Za-z][A-Za-z0-9_-]*' \
    | grep -viE '^(none|inherit|initial|unset|revert|var|infinite|alternate|reverse|both|forwards|backwards|paused|running|normal|ease|linear|ease-in|ease-out|ease-in-out|step-start|step-end)$' \
    | while IFS= read -r tok; do
        echo "$defined_all" | grep -qxF "$tok" && printf '%s\n' "$tok"
      done \
    | sort -u)

  local undefined_refs="" name
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if ! echo "$defined_all" | grep -qxF "$name"; then
      undefined_refs+="$name"$'\n'
    fi
  done <<< "$referenced"

  local unused=""
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if ! echo "$referenced" | grep -qxF "$name"; then
      unused+="$name"$'\n'
    fi
  done <<< "$theme_defined"

  local ok=true
  if [ -n "${undefined_refs//[$'\n']/}" ]; then
    echo -e "${RED}✗ animation references an undefined @keyframes:${NC}"
    echo "$undefined_refs" | sed '/^$/d'
    FAILED=1
    TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + $(echo "$undefined_refs" | sed '/^$/d' | grep -c "^")))
    ok=false
  fi
  if [ -n "${unused//[$'\n']/}" ]; then
    echo -e "${YELLOW}⚠ @keyframes defined but never referenced (dead code):${NC}"
    echo "$unused" | sed '/^$/d'
    ok=false
  fi
  if [ "$ok" = true ]; then
    echo -e "${GREEN}✓ All @keyframes are defined and used${NC}"
  fi
  echo ""
}

# Function to test a single theme
test_theme() {
  local theme_path="$1"
  local theme_name=$(basename "$theme_path")

  echo ""
  echo "🎨 Testing theme: $theme_name"
  echo "================================"

  local theme_failed=0
  FAILED=0  # Reset per-theme failure flag

  test_token_usage "$theme_path"
  test_duplicate_tokens "$theme_path"
  test_module_imports "$theme_path"
  test_keyframes "$theme_path"
  test_hardcoded_spacing "$theme_path"
  test_hardcoded_borders "$theme_path"
  test_hardcoded_dimensions "$theme_path"

  THEMES_TESTED=$((THEMES_TESTED + 1))
  if [ $FAILED -eq 1 ]; then
    THEMES_FAILED=$((THEMES_FAILED + 1))
  fi
}

# Discover themes to test
if [ -n "$1" ]; then
  # Specific theme provided as argument
  THEME_PATH="$THEMES_BASE/$1"
  if [ ! -d "$THEME_PATH" ]; then
    echo -e "${RED}❌ Theme not found: $1${NC}"
    echo "Available themes:"
    ls -1 "$THEMES_BASE" 2>/dev/null || echo "  (no themes directory found)"
    exit 1
  fi
  THEMES=("$THEME_PATH")
else
  # Test all themes
  if [ ! -d "$THEMES_BASE" ]; then
    echo -e "${RED}❌ Themes directory not found: $THEMES_BASE${NC}"
    exit 1
  fi
  THEMES=($(find "$THEMES_BASE" -mindepth 1 -maxdepth 1 -type d))
fi

# Run tests for each theme
for theme in "${THEMES[@]}"; do
  test_theme "$theme"
done

# Overall summary
echo ""
echo "================================"
echo "📊 Summary"
echo "================================"
echo "Themes tested: $THEMES_TESTED"
if [ $THEMES_FAILED -eq 0 ]; then
  echo -e "${GREEN}✅ All themes passed!${NC}"
  echo "All theme CSS files are properly tokenized."
  exit 0
else
  echo -e "${RED}❌ $THEMES_FAILED theme(s) failed!${NC}"
  echo "Found $TOTAL_VIOLATIONS total violations across all themes."
  echo ""
  echo "Fix suggestions:"
  echo "  • Replace hardcoded spacing with spacing tokens (--space-*)"
  echo "  • Replace hardcoded borders with border tokens (--border-width-*)"
  echo "  • Use calc() with tokens for complex values"
  echo "  • Add new tokens to variables.css if needed"
  exit 1
fi
