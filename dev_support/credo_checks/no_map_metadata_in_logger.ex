defmodule CredoChecks.NoMapMetadataInLogger do
  @moduledoc """
  Flags Logger calls that pass a map literal as the metadata argument.

  `logger_json` (and the standard Logger backend) only captures keyword list
  metadata. Map literals are silently dropped, meaning the structured fields
  never appear in JSON log output or log aggregation systems.

  ## Examples

      # Bad — map literal is silently dropped by logger_json
      Logger.info("User registered", %{user_id: user.id, email: user.email})
      Logger.error("Payment failed", %{reason: reason, amount: amount})

      # Good — keyword list is captured and emitted as structured fields
      Logger.info("User registered", user_id: user.id, email: user.email)
      Logger.error("Payment failed", reason: reason, amount: amount)
  """

  use Credo.Check,
    base_priority: :low,
    category: :design,
    explanations: [
      check: """
      Logger metadata must be a keyword list, not a map. Maps are silently
      dropped by logger_json and the standard Logger backend, so structured
      fields never appear in log output.

      Bad:
          Logger.info("User registered", %{user_id: id})

      Good:
          Logger.info("User registered", user_id: id)
      """
    ]

  alias Credo.IssueMeta

  @logger_levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]

  @doc false
  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: list()
  def run(%Credo.SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # Logger.level("message", %{map: literal})
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Logger]}, level]}, meta, [_message, metadata]} = ast,
         issues,
         issue_meta
       )
       when level in @logger_levels do
    if map_literal?(metadata) do
      issue =
        format_issue(issue_meta,
          message:
            "Logger metadata must be a keyword list, not a map. " <>
              "Maps are silently dropped by logger_json.",
          line_no: meta[:line],
          trigger: "Logger.#{level}"
        )

      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp map_literal?({:%{}, _, _}), do: true
  defp map_literal?(_), do: false
end
