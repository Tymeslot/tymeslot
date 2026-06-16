defmodule CredoChecks.UseColorScale do
  @moduledoc """
  Ensures the canonical `tymeslot-*` gray scale is used instead of Tailwind's
  built-in gray-family scales.

  Tailwind ships five interchangeable gray palettes. This project standardizes
  on `tymeslot-*` to keep the codebase consistent. All other gray-family
  scales are banned:

      # Bad
      class="text-gray-900 bg-slate-50 border-neutral-200"

      # Good
      class="text-tymeslot-900 bg-tymeslot-50 border-tymeslot-200"

  Banned scales: `gray`, `slate`, `zinc`, `stone`, `neutral`.
  """

  use Credo.Check,
    base_priority: :low,
    category: :design,
    exit_status: 0,
    explanations: [
      check: """
      Use `tymeslot-*` instead of Tailwind's built-in gray scales
      (`gray-*`, `slate-*`, `zinc-*`, `stone-*`, `neutral-*`).
      """,
      params: [
        banned_color_scales:
          "List of Tailwind color scale names to ban (default: gray, slate, zinc, stone, neutral)"
      ]
    ],
    param_defaults: [
      banned_color_scales: ~w(gray slate zinc stone neutral)
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

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    if skip_file?(source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      lines = SourceFile.lines(source_file)
      banned_scales = Params.get(params, :banned_color_scales, __MODULE__)
      regex = build_regex(banned_scales)

      Enum.reduce(lines, [], fn {line_no, line}, issues ->
        case Regex.run(regex, line) do
          [match | _] ->
            [issue_for(issue_meta, line_no, match) | issues]

          nil ->
            issues
        end
      end)
    end
  end

  defp skip_file?(filename) do
    String.contains?(filename, "use_color_scale.ex") or
      String.contains?(filename, "tailwind.config") or
      String.contains?(filename, "/assets/")
  end

  defp build_regex(banned_scales) do
    prefixes = Enum.join(@color_prefixes, "|")
    scales = Enum.join(banned_scales, "|")
    Regex.compile!("(?:#{prefixes})-(?:#{scales})-\\d+")
  end

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(issue_meta,
      message:
        "Use `tymeslot-*` instead of `#{trigger}`. See color scales in the @theme block of assets/css/app.css.",
      line_no: line_no,
      trigger: trigger
    )
  end
end
