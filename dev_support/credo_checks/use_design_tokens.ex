defmodule CredoChecks.UseDesignTokens do
  @moduledoc """
  Ensures design token classes are used instead of raw Tailwind defaults.

  This check detects three categories of violations in Tailwind class strings:

  ## Banned color scales

  The project uses `tymeslot-*` for grayscale colors. All other gray-family
  scales — including Tailwind's built-in `neutral` — are banned:

      # Bad
      class="text-gray-900 bg-slate-50 border-neutral-200"

      # Good
      class="text-tymeslot-900 bg-tymeslot-50 border-tymeslot-200"

  Banned scales: `gray`, `slate`, `zinc`, `stone`, `neutral`.

  ## Raw font sizes

  Font sizes must use token-prefixed classes that map to CSS variables:

      # Bad
      class="text-xl text-2xl"

      # Good
      class="text-token-xl text-token-2xl"

  Applies to sizes: `xs`, `sm`, `base`, `lg`, `xl`, `2xl`–`7xl`.

  ## Raw border radii

  Border radii must use token-prefixed classes, including directional variants:

      # Bad
      class="rounded-xl rounded-2xl rounded-t-lg rounded-tl-xl"

      # Good
      class="rounded-token-xl rounded-token-2xl rounded-t-token-lg rounded-tl-token-xl"

  Applies to sizes: `sm`, `md`, `lg`, `xl`, `2xl`, `3xl`.
  `rounded`, `rounded-full`, and `rounded-none` are allowed (no token equivalents).

  ## Arbitrary values

  Hardcoded hex colors and arbitrary font/radius values are banned:

      # Bad
      class="bg-[#333] text-[18px] rounded-[12px]"

      # Good — use design token classes or CSS variables
      class="bg-tymeslot-800 text-token-lg rounded-token-lg"
  """

  use Credo.Check,
    base_priority: :low,
    category: :design,
    exit_status: 0,
    explanations: [
      check: """
      Use design token classes instead of raw Tailwind defaults.

      - Colors: use `tymeslot-*` instead of `gray-*`, `slate-*`, `zinc-*`, `stone-*`, `neutral-*`
      - Font sizes: use `text-token-*` instead of `text-xs`, `text-xl`, etc.
      - Border radius: use `rounded-token-*` instead of `rounded-sm`, `rounded-xl`, etc.
      - No arbitrary hex colors (`bg-[#...]`) or arbitrary sizes (`text-[18px]`, `rounded-[12px]`)
      """,
      params: [
        banned_color_scales:
          "List of Tailwind color scale names to ban (default: gray, slate, zinc, stone)",
        check_font_sizes: "Whether to check for raw font size classes (default: true)",
        check_border_radius: "Whether to check for raw border radius classes (default: true)",
        check_arbitrary_values:
          "Whether to check for arbitrary hex/size values (default: true)"
      ]
    ],
    param_defaults: [
      banned_color_scales: ~w(gray slate zinc stone neutral),
      check_font_sizes: true,
      check_border_radius: true,
      check_arbitrary_values: true
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  # Tailwind utility prefixes that accept color scales
  @color_prefixes ~w(
    text bg border ring divide
    from to via
    placeholder outline accent
    decoration shadow
    fill stroke
  )

  # Font sizes that have token equivalents (text-token-*)
  @token_font_sizes ~w(xs sm base lg xl 2xl 3xl 4xl 5xl 6xl 7xl)

  # Border radii that have token equivalents (rounded-token-*)
  @token_border_radii ~w(sm md lg xl 2xl 3xl)

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    filename = source_file.filename

    if skip_file?(filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      lines = SourceFile.lines(source_file)
      banned_scales = Params.get(params, :banned_color_scales, __MODULE__)
      check_fonts? = Params.get(params, :check_font_sizes, __MODULE__)
      check_radius? = Params.get(params, :check_border_radius, __MODULE__)
      check_arbitrary? = Params.get(params, :check_arbitrary_values, __MODULE__)

      color_regex = build_color_regex(banned_scales)

      font_size_regex =
        if check_fonts?,
          do: build_font_size_regex(),
          else: nil

      border_radius_regex =
        if check_radius?,
          do: build_border_radius_regex(),
          else: nil

      arbitrary_color_regex =
        if check_arbitrary?,
          do:
            ~r/(?:text|bg|border|ring|from|to|via|fill|stroke|outline|accent|decoration|shadow|divide|placeholder)-\[#[0-9a-fA-F]+\]/,
          else: nil

      arbitrary_font_regex =
        if check_arbitrary?,
          do: ~r/(?<!\w)text-\[\d+(?:\.\d+)?(?:px|rem|em)\]/,
          else: nil

      arbitrary_radius_regex =
        if check_arbitrary?,
          do: ~r/(?<!\w)rounded(?:-[a-z]+)?-\[\d+(?:\.\d+)?(?:px|rem|em)\]/,
          else: nil

      Enum.reduce(lines, [], fn {line_no, line}, issues ->
        issues
        |> check_pattern(color_regex, line, line_no, issue_meta, :color)
        |> check_pattern(font_size_regex, line, line_no, issue_meta, :font_size)
        |> check_pattern(border_radius_regex, line, line_no, issue_meta, :border_radius)
        |> check_pattern(arbitrary_color_regex, line, line_no, issue_meta, :arbitrary_color)
        |> check_pattern(arbitrary_font_regex, line, line_no, issue_meta, :arbitrary_font)
        |> check_pattern(arbitrary_radius_regex, line, line_no, issue_meta, :arbitrary_radius)
      end)
    end
  end

  defp skip_file?(filename) do
    String.contains?(filename, "use_design_tokens.ex") or
      String.contains?(filename, "tailwind.config") or
      String.contains?(filename, "/assets/")
  end

  defp check_pattern(issues, nil, _line, _line_no, _issue_meta, _type), do: issues

  defp check_pattern(issues, regex, line, line_no, issue_meta, type) do
    case Regex.run(regex, line) do
      [match | _] ->
        [issue_for(issue_meta, line_no, match, type) | issues]

      nil ->
        issues
    end
  end

  defp build_color_regex(banned_scales) do
    prefixes = Enum.join(@color_prefixes, "|")
    scales = Enum.join(banned_scales, "|")
    Regex.compile!("(?:#{prefixes})-(?:#{scales})-\\d+")
  end

  defp build_font_size_regex do
    sizes = Enum.join(@token_font_sizes, "|")
    # Match text-xl but not text-token-xl, text-white, text-neutral-*, etc.
    # Negative lookahead (?!-) prevents matching text-sm- (part of a longer class)
    Regex.compile!("(?<![\\w-])text-(?:#{sizes})(?![\\w-])")
  end

  defp build_border_radius_regex do
    sizes = Enum.join(@token_border_radii, "|")
    # Match rounded-xl, rounded-t-xl, rounded-tl-xl, etc. but not rounded-token-xl
    Regex.compile!(
      "(?<![\\w-])rounded(?:-(?:t|r|b|l|tl|tr|bl|br|s|e|ss|se|es|ee))?-(?:#{sizes})(?![\\w-])"
    )
  end

  defp issue_for(issue_meta, line_no, trigger, type) do
    message =
      case type do
        :color ->
          "Use `tymeslot-*` instead of `#{trigger}`. See design tokens in tailwind.config.js."

        :font_size ->
          token = String.replace(trigger, "text-", "text-token-")

          "Use `#{token}` instead of `#{trigger}`. Design token font sizes use the `token-` prefix."

        :border_radius ->
          token = String.replace(trigger, "rounded-", "rounded-token-")

          "Use `#{token}` instead of `#{trigger}`. Design token border radii use the `token-` prefix."

        :arbitrary_color ->
          "Avoid arbitrary hex colors (`#{trigger}`). Use a design token color scale (e.g., `tymeslot-*`, `turquoise-*`, `cyan-*`)."

        :arbitrary_font ->
          "Avoid arbitrary font sizes (`#{trigger}`). Use a design token size (e.g., `text-token-lg`)."

        :arbitrary_radius ->
          "Avoid arbitrary border radii (`#{trigger}`). Use a design token radius (e.g., `rounded-token-xl`)."
      end

    format_issue(issue_meta,
      message: message,
      line_no: line_no,
      trigger: trigger
    )
  end
end
