defmodule CredoChecks.ProviderResponseBoundary do
  @moduledoc """
  Flags a video provider reading an HTTP response body outside
  `Tymeslot.Integrations.Shared.ApiResponse`.

  `ApiResponse.handle_tagged/2` is the one place an unmodelled provider body
  is decoded, logged and redacted. A provider that pattern-matches
  `%Req.Response{body: body}` itself has to remember
  `Redactor.redact_and_truncate/1` on every new endpoint, and the copy that
  forgets is the one that leaks a token into the logs.

  Flagged: a `%Req.Response{}` pattern (or `%Response{}`, the usual alias)
  that names the `body` field, in a file under
  `lib/tymeslot/integrations/video/`. Matching on the status alone stays
  allowed, since a status decides control flow (a 401 that triggers a token
  refresh) without touching the body. Provider-specific reading of a body
  belongs in a `:custom` or `:detail` callback, which receives a plain map.

  ## Excluded files

  - Test files
  - An `:allowed` param (list of filename substrings), for a client with a
    reviewed reason to read bodies itself. Nextcloud Talk is one: its OCS
    envelope is parsed for data and refusals, never logged.

        {CredoChecks.ProviderResponseBoundary,
         [allowed: ["lib/tymeslot/integrations/video/providers/nextcloud_talk/client.ex"]]}

  ## Examples

      # Bad: a hand-rolled tree that must remember redaction itself
      case request(...) do
        {:ok, %Req.Response{status: 200, body: body}} -> Jason.decode(body)
        {:ok, %Req.Response{status: status, body: body}} -> log(status, body)
      end

      # Good
      request(...) |> ApiResponse.handle_tagged(label: "Provider")
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [allowed: []],
    explanations: [
      check: """
      Video providers read response bodies through
      `Tymeslot.Integrations.Shared.ApiResponse.handle_tagged/2`, the one place
      an unmodelled body is logged and redacted.
      """,
      params: [
        allowed: "List of filename substrings allowed to read response bodies directly."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.Code
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @scope "lib/tymeslot/integrations/video/"

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    filename = source_file.filename
    allowed = Params.get(params, :allowed, __MODULE__)

    if in_scope?(filename) and not Enum.any?(allowed, &String.contains?(filename, &1)) do
      issue_meta = IssueMeta.for(source_file, params)
      Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    else
      []
    end
  end

  defp in_scope?(filename),
    do: String.contains?(filename, "/" <> @scope) or String.starts_with?(filename, @scope)

  defp traverse(
         {:%, meta, [{:__aliases__, _, aliases}, {:%{}, _, fields}]} = ast,
         issues,
         issue_meta
       )
       when aliases in [[:Req, :Response], [:Response]] and is_list(fields) do
    if Keyword.has_key?(fields, :body),
      do: {ast, [issue(issue_meta, meta[:line], Enum.join(aliases, ".")) | issues]},
      else: {ast, issues}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp issue(issue_meta, line_no, struct) do
    format_issue(issue_meta,
      message:
        "`%#{struct}{body: ...}` reads a provider body outside `ApiResponse`. Route the " <>
          "response through `ApiResponse.handle_tagged/2`, with a `:custom` or `:detail` " <>
          "callback for what the provider says differently.",
      line_no: line_no,
      trigger: "%#{struct}{"
    )
  end
end
