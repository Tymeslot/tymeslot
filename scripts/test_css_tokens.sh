#!/usr/bin/env bash
# CSS Design Token Validator
# Tests for hardcoded values in all theme CSS files and the shared component
# styles (shared/components/), and for colour literals outside the token files
# Usage: ./scripts/test_css_tokens.sh [theme_name]
#   Without arguments: checks all themes
#   With theme_name: checks only that theme

set -e

# Overridable so the checks can be tested against a fixture tree.
SCHEDULING_CSS_ROOT="${SCHEDULING_CSS_ROOT:-assets/css/scheduling}"
THEMES_BASE="$SCHEDULING_CSS_ROOT/themes"
LITERALS_FAILED=0
EMBED_QUERIES_FAILED=0
SHARED_FAILED=0
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

# Every token a theme's modules/variables.css must define: the token contract
# documented in shared/tokens.css, plus every token the shared styles read
# that no shared file defines (test_shared_token_contract keeps that part
# complete). Tokens shared/tokens.css defaults on :where(:root) are not
# listed; a theme may still set them.
REQUIRED_TOKENS=(
  "--space-3xs"
  "--space-2xs"
  "--space-xs"
  "--space-sm"
  "--space-md"
  "--space-lg"
  "--space-xl"
  "--space-2xl"
  # The token contract (documented in shared/tokens.css): palette and
  # status inputs, shadow geometry, roles and the shared screens' tokens.
  # --theme-background is left out on purpose.
  "--theme-primary"
  "--theme-primary-hover"
  "--theme-secondary"
  "--theme-accent"
  "--theme-on-primary"
  "--theme-on-accent"
  "--theme-text"
  "--theme-text-secondary"
  "--theme-canvas"
  "--theme-success"
  "--theme-warning"
  "--theme-danger"
  "--theme-info"
  "--shadow-geometry-sm"
  "--shadow-geometry-md"
  "--shadow-geometry-lg"
  "--surface-2"
  "--surface-3"
  "--ink-1"
  "--ink-2"
  "--ink-3"
  "--notice-warning-surface"
  "--notice-warning-border"
  "--radius-control"
  "--radius-card"
  "--theme-font-family"
  "--status-surface"
  "--status-surface-opaque"
  "--status-shadow"
  "--status-ink-heading"
  "--status-ink"
  "--status-ink-soft"
  "--status-ink-hint"
  # The seat badge's traffic light (shared/components/slot-list.css): each
  # theme picks its own colours for it.
  "--seat-green"
  "--seat-green-bg"
  "--seat-amber"
  "--seat-amber-bg"
  "--seat-red"
  "--seat-red-bg"
  "--seat-neutral"
  "--seat-neutral-bg"
  "--seat-selected"
  "--seat-selected-bg"
  # Tokens the shared component styles (shared/components/*.css) read.
  "--approval-icon-surface"
  "--approval-notice-font-size"
  "--approval-notice-gap"
  "--approval-notice-ink"
  "--approval-notice-max-width"
  "--approval-pill-surface"
  "--poll-input-focus-ring"
  "--poll-input-line"
  "--poll-input-surface"
  "--poll-option-line"
  "--poll-option-selected-surface"
  "--poll-panel-surface"
  "--poll-row-line"
  "--poll-row-surface"
  "--poll-voting-padding"
  "--payment-body-ink"
  "--payment-card-line"
  "--payment-card-radius"
  "--payment-card-surface"
  "--payment-heading-ink"
  "--payment-link-radius"
  "--payment-link-transition"
  "--payment-link-weight"
  "--payment-page-max-width"
  "--lang-switcher-surface"
  "--lang-switcher-surface-hover"
  "--lang-switcher-panel-surface"
  "--lang-switcher-panel-line"
  "--lang-switcher-item-line"
  "--lang-switcher-item-hover"
  "--lang-switcher-item-active"
  "--slot-list-grid-gap"
  "--guest-remove-ink-hover"
  "--dropdown-surface"
  # The scale tokens the shared styles read. With the entries above, this is
  # every var() that shared/*.css reads without a fallback and no shared file
  # defines; test_shared_token_contract fails when a new one is not listed.
  "--border-subtle"
  "--border-light"
  "--border-medium"
  "--surface-subtle"
  "--surface-light"
  "--surface-medium"
  "--surface-intense"
  "--theme-error-light"
  "--theme-font-size-3xs"
  "--theme-font-size-2xs"
  "--theme-font-size-xs"
  "--theme-font-size-sm"
  "--theme-font-size-base"
  "--theme-font-size-md"
  "--theme-font-size-lg"
  "--theme-font-size-2xl"
  "--theme-font-size-3xl"
  "--letter-spacing-wide"
  "--space-hairline"
  "--icon-sm"
  "--shadow-md"
)

# Shared files every theme's theme.css must import: the entry, the token
# contract and the embed rules, and each shared component file whose markup
# every theme renders through shared code. A file a theme may replace with its
# own markup (slot-list, timezone-picker, week-grid, manage-pages) is not
# listed. One entry per line, quoted: the ExUnit test reads the list from here.
REQUIRED_SHARED_IMPORTS=(
  "shared/entry.css"
  "shared/tokens.css"
  "shared/embed.css"
  "shared/components/language-switcher.css"
  "shared/components/preview-notice.css"
  "shared/components/flash.css"
  "shared/components/approval-notice.css"
  "shared/components/booking-fields.css"
  "shared/components/custom-questions.css"
  "shared/components/polls.css"
  "shared/components/payment-pages.css"
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

# Like stripped_css_lines, but with every selector and at-rule prelude (the
# text before a "{", back to the previous "{", "}" or ";") blanked as well, so
# only declarations remain. A selector list spread over several lines is
# blanked whole, so an ID such as "#add-guest," can never read as a hex colour.
declaration_css_lines() {
  local root="$1"
  find "$root" -name "*.css" -type f | sort | while IFS= read -r f; do
    perl -0777 -pe '
      s{/\*.*?\*/}{ $x = $&; $x =~ tr/\n//cd; $x }ges;
      s{(^|[{};])([^{};]*)(?=\{)}{ $y = $2; $y =~ tr/\n//cd; $1 . $y }ge;
    ' "$f" \
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

  if [ ! -f "$tokens_file" ]; then
    echo -e "${RED}✗ No modules/variables.css: every theme defines its tokens there${NC}"
    FAILED=1
    TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + 1))
    echo ""
    return 0
  fi


  local missing_tokens=0
  for token in "${REQUIRED_TOKENS[@]}"; do
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

  # A missing file is reported once, by test_token_usage.
  if [ ! -f "$tokens_file" ]; then
    echo ""
    return 0
  fi

  local duplicates=$(grep -oE '^[[:space:]]*--[A-Za-z0-9_-]+[[:space:]]*:' "$tokens_file" \
    | sed -E 's/^[[:space:]]*//; s/[[:space:]]*:$//' | sort | uniq -d)

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
  if [ ! -f "$theme_css" ]; then
    echo -e "${RED}✗ No theme.css: every theme's stylesheet starts there${NC}"
    FAILED=1
    TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + 1))
    echo ""
    return 0
  fi
  if [ ! -d "$theme_path/modules" ]; then
    echo -e "${YELLOW}⚠ No modules/ - skipping the orphan check${NC}"
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

  # Shared booking CSS sits beside the themes dir. Every theme.css imports
  # shared/entry.css (reset, layout, utilities and the other primitives) and
  # shared/tokens.css, and picks the shared/components/*.css files it uses, so
  # keyframes defined anywhere under shared/ (e.g. `spin`) count as defined.
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

# A media query on the viewport's height (height, aspect-ratio, orientation)
# sees the iframe's own height inside an embed, and iframe_embed.js sets that
# height from the content. A rule that changes the content's height at a
# threshold then decides the very height it tests, so the page can settle
# above or below the threshold depending on the step the visitor came from.
# Every such @media block therefore holds exactly one rule,
# `:where(html:not([data-embedded])) { ... }`, with the block's rules nested
# inside it: they apply to a page opened on its own and never to an embed, at
# the specificity they had without the wrapper. Scans the whole scheduling tree.
test_embed_height_queries() {
  echo "📐 Testing that no height media query applies to an embedded page..."

  local violations
  violations=$(find "$SCHEDULING_CSS_ROOT" -name "*.css" -type f | sort | while IFS= read -r f; do
    perl -0777 -ne '
      s{/\*.*?\*/}{ $x = $&; $x =~ tr/\n//cd; $x }ges;
      my $css = $_;
      # The index just past the brace that closes the one opened before $from.
      sub close_of { my ($s, $from) = @_; my $depth = 1; my $i = $from;
        while ($depth && $i < length $s) { my $c = substr($s, $i, 1);
          $depth++ if $c eq "{"; $depth-- if $c eq "}"; $i++ } $i }
      while ($css =~ /\@media([^{;]*)\{/g) {
        my ($prelude, $start) = ($1, pos($css));
        next unless $prelude =~ /\b(?:min-|max-)?(?:device-)?(?:height|aspect-ratio|orientation)\b/;
        my $body = substr($css, $start, close_of($css, $start) - 1 - $start);
        my $ok = 0;
        if ($body =~ /\A\s*:where\(html:not\(\[data-embedded\]\)\)\s*\{/g) {
          $ok = substr($body, close_of($body, pos($body))) =~ /\A\s*\z/;
        }
        unless ($ok) {
          my $line = 1 + (substr($css, 0, $start) =~ tr/\n//);
          $prelude =~ s/^\s+|\s+$//g;
          print "$ARGV:$line: \@media $prelude\n";
        }
        pos($css) = $start;
      }
    ' "$f"
  done)

  if [ -n "$violations" ]; then
    echo -e "${RED}✗ Height media queries that also apply to an embedded page (nest the block's rules in :where(html:not([data-embedded]))):${NC}"
    echo "$violations"
    EMBED_QUERIES_FAILED=1
    TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + $(echo "$violations" | grep -c "^")))
  else
    echo -e "${GREEN}✓ Every height media query leaves embedded pages alone${NC}"
  fi
  echo ""
}

# Colour literals (rgb(), rgba(), hsl(), hsla(), hex) belong only in token
# files: each theme's modules/variables.css, shared/tokens.css, and
# shared/brand-tokens.css (the Tailwind @theme block). Everything else reads
# colours through tokens, so a custom palette, a new theme or a light mode
# changes them in one place. Scans the whole scheduling tree, shared files
# included; selectors are blanked first (declaration_css_lines) so an ID can
# never look like a hex.
test_colour_literals() {
  echo "🎨 Testing for colour literals outside the token files..."

  local violations
  violations=$(declaration_css_lines "$SCHEDULING_CSS_ROOT" \
    | grep -vE '(/modules/variables\.css|/shared/tokens\.css|/shared/brand-tokens\.css):[0-9]+:' \
    | grep -E '^[^:]+:[0-9]+:.*((rgba?|hsla?)\(|#[0-9a-fA-F]{3,8}\b)' \
    || true)

  if [ -n "$violations" ]; then
    echo -e "${RED}✗ Found colour literals outside the token files (move them into variables.css):${NC}"
    echo "$violations"
    LITERALS_FAILED=1
    TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + $(echo "$violations" | grep -c "^")))
  else
    echo -e "${GREEN}✓ No colour literals outside the token files${NC}"
  fi
  echo ""
}

# The shared component styles (shared/components/) hold rules moved out of
# the themes, and the blocks (shared/blocks/) the markup any theme may render
# for a fact, so both follow the same spacing and border-width rules.
test_shared_components() {
  local dir path
  for dir in components blocks; do
    path="$SCHEDULING_CSS_ROOT/shared/$dir"
    [ -d "$path" ] || continue

    echo ""
    echo "🧩 Testing shared $dir: $path"
    echo "================================"

    FAILED=0
    test_hardcoded_spacing "$path"
    test_hardcoded_borders "$path"
    [ $FAILED -eq 1 ] && SHARED_FAILED=1
  done
  return 0
}

# The shared styles (shared/) read tokens only a theme defines. Every var()
# they read without a fallback must be defined in a shared file or be listed
# in REQUIRED_TOKENS, so a theme that passes test_token_usage defines them
# all; a token the theme leaves out would silently drop every declaration
# reading it.
test_shared_token_contract() {
  local shared="$SCHEDULING_CSS_ROOT/shared"
  [ -d "$shared" ] || return 0
  echo "📜 Testing that REQUIRED_TOKENS covers every token shared/ reads..."

  local css read defined undeclared
  css=$(stripped_css_lines "$shared" | cut -d: -f3-)
  read=$(printf '%s\n' "$css" \
    | grep -oE 'var\(--[A-Za-z0-9_-]+[[:space:]]*[,)]' \
    | grep -vE ',$' \
    | sed -E 's/^var\(//; s/[[:space:]]*\)$//' | sort -u || true)
  defined=$( { printf '%s\n' "$css" \
      | grep -oE '(^|[;{[:space:]])--[A-Za-z0-9_-]+[[:space:]]*:' \
      | grep -oE -- '--[A-Za-z0-9_-]+' || true
    printf '%s\n' "${REQUIRED_TOKENS[@]}"; } | sort -u)
  undeclared=$(comm -23 <(printf '%s\n' "$read") <(printf '%s\n' "$defined") | sed '/^$/d')

  if [ -n "$undeclared" ]; then
    echo -e "${RED}✗ Tokens read in shared/ that no shared file defines and REQUIRED_TOKENS does not list:${NC}"
    echo "$undeclared"
    SHARED_FAILED=1
    TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + $(echo "$undeclared" | grep -c "^")))
  else
    echo -e "${GREEN}✓ Every token shared/ reads is defined there or required of each theme${NC}"
  fi
  echo ""
}

# Every file in REQUIRED_SHARED_IMPORTS is imported by the theme's theme.css:
# an @import naming it with any relative prefix and either quote, or url(),
# outside a comment.
test_shared_imports() {
  local theme_path="$1"
  local theme_css="$theme_path/theme.css"
  echo "🔗 Testing the shared imports every theme needs..."
  [ -f "$theme_css" ] || { echo ""; return 0; }

  local imports missing=0 file
  imports=$(perl -0777 -pe 's{/\*.*?\*/}{}gs' "$theme_css" \
    | grep -oE "@import[[:space:]]+(url\()?[\"'][^\"']+[\"']" \
    | sed -E "s/^@import[[:space:]]+(url\()?[\"']//; s/[\"']$//; s#^(\.\./|\./)+##")

  for file in "${REQUIRED_SHARED_IMPORTS[@]}"; do
    if ! printf '%s\n' "$imports" | grep -qxF -- "$file"; then
      echo -e "${RED}✗ Missing shared import: $file${NC}"
      missing=$((missing + 1))
      FAILED=1
    fi
  done

  if [ "$missing" -eq 0 ]; then
    echo -e "${GREEN}✓ All shared imports every theme needs are present${NC}"
  else
    TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + missing))
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
  test_shared_imports "$theme_path"
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

test_shared_components
test_shared_token_contract
test_colour_literals
test_embed_height_queries

# Overall summary
echo ""
echo "================================"
echo "📊 Summary"
echo "================================"
echo "Themes tested: $THEMES_TESTED"
if [ $THEMES_FAILED -eq 0 ] && [ $SHARED_FAILED -eq 0 ] && [ $LITERALS_FAILED -eq 0 ] && [ $EMBED_QUERIES_FAILED -eq 0 ]; then
  echo -e "${GREEN}✅ All themes passed!${NC}"
  echo "All theme CSS files are properly tokenized."
  exit 0
else
  echo -e "${RED}❌ CSS token checks failed!${NC}"
  echo "Found $TOTAL_VIOLATIONS total violations across all themes."
  echo ""
  echo "Fix suggestions:"
  echo "  • Replace hardcoded spacing with spacing tokens (--space-*)"
  echo "  • Replace hardcoded borders with border tokens (--border-width-*)"
  echo "  • Use calc() with tokens for complex values"
  echo "  • Add new tokens to variables.css if needed"
  echo "  • Move colour literals into the theme's variables.css and read them through a token"
  echo "  • Nest a height media query's rules in :where(html:not([data-embedded]))"
  exit 1
fi
