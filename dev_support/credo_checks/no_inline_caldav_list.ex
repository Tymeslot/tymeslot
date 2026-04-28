defmodule CredoChecks.NoInlineCaldavList do
  @moduledoc """
  Flags inline lists of CalDAV-based providers in `lib/` files.

  The CalDAV-provider list lives in `Tymeslot.Integrations.Calendar.ProviderConfig`
  (`caldav_based_providers/0` and `caldav_based_provider_strings/0`). Re-declaring
  it inline as `[:caldav, :radicale, :nextcloud, :zimbra]` or
  `~w(caldav radicale nextcloud zimbra)` means every new provider has to be added
  in two places — and forgotten in one of them is precisely the bug that
  motivated this check.

  ## Rule

  A line in `*.ex` / `*.exs` under `lib/` is flagged when it contains both a
  `caldav` and a `radicale` token (atom or string), in either order. Every
  inline CalDAV-family list in the codebase has historically included
  `radicale`, so requiring it as a second token gives a strong signal while
  leaving marketing copy that only mentions the popular two providers (CalDAV
  + Nextcloud) alone.

  Tests, migrations, deps, and the canonical registry files are excluded.
  Typespec / spec / callback / opaque lines are exempt — declaring
  `@type provider :: :caldav | :nextcloud | …` is a separate kind of
  enumeration.

  ## Whitelisted files

  - `provider_config.ex` — the canonical source.
  - `provider_registry.ex` — the provider → module map.
  - `articles.ex` — docs-site SEO tag list that happens to share provider
    words; not a runtime provider list.
  """

  use Credo.Check,
    base_priority: :normal,
    category: :design,
    explanations: [
      check: """
      Inline CalDAV-provider lists drift out of sync with
      `Tymeslot.Integrations.Calendar.ProviderConfig.caldav_based_providers/0`
      every time a new provider is added. Replace the literal with a module
      attribute that calls the central helper at compile time:

          @caldav_providers ProviderConfig.caldav_based_providers()
          # or, for string-shaped lists:
          @caldav_provider_strings ProviderConfig.caldav_based_provider_strings()
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @whitelisted_paths [
    "integrations/calendar/providers/provider_config.ex",
    "integrations/calendar/providers/provider_registry.ex",
    "docs_live/articles.ex"
  ]

  # Match `caldav` followed (anywhere on the line) by `radicale`, or vice
  # versa, in either atom or string form. The `(?:^|[^a-zA-Z0-9_])` and
  # `(?![a-zA-Z0-9_])` boundaries avoid matching identifiers like
  # `caldavclient` or `:radicale_helper`.
  @inline_list_pattern ~r/(?:^|[^a-zA-Z0-9_])(?::caldav|"caldav")(?![a-zA-Z0-9_]).*(?:^|[^a-zA-Z0-9_])(?::radicale|"radicale")(?![a-zA-Z0-9_])|(?:^|[^a-zA-Z0-9_])(?::radicale|"radicale")(?![a-zA-Z0-9_]).*(?:^|[^a-zA-Z0-9_])(?::caldav|"caldav")(?![a-zA-Z0-9_])/

  # Sigil form: `~w(caldav radicale ...)` or `~w(radicale caldav ...)` etc.
  # Supports all standard paired delimiters: ( [ { < / |
  @sigil_pattern ~r/~w[a-zA-Z]*[\(\[\{\<\/\|]([^\)\]\}\>\/\|]*)[\)\]\}\>\/\|]/

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    if excluded?(source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> SourceFile.lines()
      |> Enum.flat_map(&issues_for_line(&1, issue_meta))
    end
  end

  defp excluded?(filename) do
    not lib_file?(filename) or
      whitelisted?(filename) or
      String.contains?(filename, "/test/") or
      String.contains?(filename, "/migrations/") or
      String.contains?(filename, "/deps/")
  end

  defp whitelisted?(filename) do
    Enum.any?(@whitelisted_paths, &String.ends_with?(filename, &1))
  end

  defp lib_file?(filename) do
    String.contains?(filename, "/lib/") or String.starts_with?(filename, "lib/")
  end

  defp issues_for_line({line_no, line}, issue_meta) do
    cond do
      comment_line?(line) -> []
      typespec_line?(line) -> []
      Regex.match?(@inline_list_pattern, line) -> [build_issue(issue_meta, line_no)]
      sigil_caldav_radicale?(line) -> [build_issue(issue_meta, line_no)]
      true -> []
    end
  end

  defp comment_line?(line) do
    String.starts_with?(String.trim_leading(line), "#")
  end

  defp typespec_line?(line) do
    trimmed = String.trim_leading(line)

    String.starts_with?(trimmed, "@type") or
      String.starts_with?(trimmed, "@typep") or
      String.starts_with?(trimmed, "@spec") or
      String.starts_with?(trimmed, "@callback") or
      String.starts_with?(trimmed, "@opaque")
  end

  defp sigil_caldav_radicale?(line) do
    case Regex.run(@sigil_pattern, line) do
      [_, body] ->
        words = String.split(body, ~r/\s+/, trim: true)
        "caldav" in words and "radicale" in words

      _ ->
        false
    end
  end

  defp build_issue(issue_meta, line_no) do
    format_issue(issue_meta,
      message:
        "Inline CalDAV-provider list — use " <>
          "`ProviderConfig.caldav_based_providers/0` or " <>
          "`caldav_based_provider_strings/0` instead.",
      line_no: line_no,
      trigger: "caldav-list"
    )
  end
end
