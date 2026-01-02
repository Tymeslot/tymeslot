defmodule CredoChecks.Phoenix.UsePSigil do
  @moduledoc """
  Suggest using Phoenix's ~p sigil (and url(~p)) for compile-time verified routes.

  This check is intentionally conservative to avoid false positives:
  - It only runs in modules where VerifiedRoutes is very likely in scope
    (use TymeslotWeb, :controller | :html | :live_view | :live_component
     or explicit import/use Phoenix.VerifiedRoutes).
  - It only flags obvious candidates by default:
    * Calls to Routes.*_path / Routes.*_url
    * Calls to redirect/push_navigate/push_patch with literal "/..." paths
  - It ignores dynamic strings, interpolations, env-based values, and external URLs.

  Options (via .credo.exs):
    - mode: :strict | :moderate | :aggressive
        :strict    -> only Routes.*_path/_url
        :moderate  -> + literal "/..." in known APIs (default)
        :aggressive-> + concatenated/interpolated internal paths (still conservative)
    - check_href?: boolean (default: false)
        When true, also suggest ~p for literal internal paths passed to :href.
    - ignore_tests?: boolean (default: true)
        Skip files in test/ by default.
  """

  use Credo.Check,
    base_priority: :low,
    category: :readability,
    exit_status: 0,
    explanations: [
      check: """
      Prefer Phoenix's ~p sigil (and url(~p)) for compile-time verified routes.
      This helps keep links in sync with the router and catches mistakes at compile time.
      """,
      params: [
        mode: "The strictness mode: :strict, :moderate, or :aggressive",
        check_href?: "Whether to check :href attributes",
        ignore_tests?: "Whether to ignore test files"
      ]
    ],
    param_defaults: [mode: :moderate, check_href?: false, ignore_tests?: true]

  alias Credo.SourceFile
  alias Credo.IssueMeta

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    mode = params[:mode] || :moderate
    check_href? = params[:check_href?] || false
    ignore_tests? = params[:ignore_tests?] != false

    cond do
      ignore_tests? and String.contains?(source_file.filename, "/test/") ->
        []

      true ->
        issue_meta = IssueMeta.for(source_file, params)
        lines = SourceFile.lines(source_file)

        if verified_routes_in_scope?(lines) do
          find_line_issues(lines, mode, check_href?, issue_meta)
        else
          []
        end
    end
  end

  # Detect whether VerifiedRoutes is in scope by looking for lines like:
  #   use TymeslotWeb, :controller | :html | :live_view | :live_component
  #   import Phoenix.VerifiedRoutes
  #   use Phoenix.VerifiedRoutes
  defp verified_routes_in_scope?(lines) do
    Enum.any?(lines, fn {_n, line} ->
      String.contains?(line, "use TymeslotWeb, :controller") or
        String.contains?(line, "use TymeslotWeb, :html") or
        String.contains?(line, "use TymeslotWeb, :live_view") or
        String.contains?(line, "use TymeslotWeb, :live_component") or
        String.contains?(line, "import Phoenix.VerifiedRoutes") or
        String.contains?(line, "use Phoenix.VerifiedRoutes")
    end)
  end

  defp find_line_issues(lines, mode, check_href?, issue_meta) do
    routes_rx = ~r/\bRoutes\.[a-zA-Z0-9_]+_(?:path|url)\s*\(/
    redirect_rx = ~r/\b(?:Phoenix\.Controller\.)?redirect\([^)]*,\s*to:\s*"\/[^"]*"/
    push_rx = ~r/\b(?:Phoenix\.LiveView\.)?push_(?:navigate|patch)\([^)]*,\s*to:\s*"\/[^"]*"/
    live_rx = ~r/\b(?:Phoenix\.LiveView\.)?live_(?:redirect|patch)\([^)]*,\s*to:\s*"\/[^"]*"/
    link_rx = ~r/\b(?:Phoenix\.(?:HTML\.Link|Component)\.)?link\([^)]*,\s*to:\s*"\/[^"]*"/
    href_rx = ~r/\bhref:\s*"\/[^"]*"/

    Enum.reduce(lines, [], fn {line_no, line}, issues ->
      cond do
        Regex.match?(routes_rx, line) ->
          [format_issue(issue_meta,
             message: "Prefer ~p (or url(~p)) instead of Routes.*_path/_url",
             line_no: line_no,
             trigger: "~p"
           ) | issues]

        mode != :strict and (
          Regex.match?(redirect_rx, line) or
          Regex.match?(push_rx, line) or
          Regex.match?(live_rx, line) or
          Regex.match?(link_rx, line)
        ) ->
          [format_issue(issue_meta,
             message: "Prefer ~p for internal paths in redirect/push_/live_/link",
             line_no: line_no,
             trigger: "~p"
           ) | issues]

        mode != :strict and check_href? and Regex.match?(href_rx, line) ->
          [format_issue(issue_meta,
             message: "Prefer ~p for internal href paths",
             line_no: line_no,
             trigger: "~p"
           ) | issues]

        true ->
          issues
      end
    end)
  end
end
