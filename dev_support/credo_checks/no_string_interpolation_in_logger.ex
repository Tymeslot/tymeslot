defmodule CredoChecks.NoStringInterpolationInLogger do
  @moduledoc """
  Flags Logger calls whose message argument contains string interpolation.

  Interpolated messages are unqueryable in log aggregation systems: each unique
  value produces a distinct log line that cannot be grouped or counted. Move all
  dynamic data to keyword metadata instead.

  ## Examples

      # Bad — interpolation bakes dynamic data into the message string
      Logger.info("Meeting \#{meeting.id} created by user \#{user_id}")
      Logger.error("OAuth failed at \#{operation}: \#{inspect(reason)}")

      # Good — static message, variable data in keyword metadata
      Logger.info("Meeting created", meeting_id: meeting.id, user_id: user_id)
      Logger.error("OAuth failed", operation: operation, reason: inspect(reason))
  """

  use Credo.Check,
    base_priority: :low,
    category: :design,
    explanations: [
      check: """
      Logger message contains string interpolation. Move dynamic data to keyword
      metadata instead so log lines are stable and queryable in aggregation systems.

      Bad:
          Logger.info("Meeting \#{id} created by user \#{user_id}")

      Good:
          Logger.info("Meeting created", meeting_id: id, user_id: user_id)
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

  # Logger.level("interpolated #{message}")
  # Logger.level("interpolated #{message}", metadata)
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Logger]}, level]}, meta, [message | _]} = ast,
         issues,
         issue_meta
       )
       when level in @logger_levels do
    if interpolated_binary?(message) do
      issue =
        format_issue(issue_meta,
          message:
            "Logger message contains string interpolation. " <>
              "Move dynamic data to keyword metadata instead.",
          line_no: meta[:line],
          trigger: "Logger.#{level}"
        )

      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  # An interpolated binary is a {:<<>>, _, parts} node that contains at least
  # one {:"::", _, [expr, {:binary, _, nil}]} interpolation segment.
  defp interpolated_binary?({:<<>>, _, parts}) do
    Enum.any?(parts, fn
      {:"::", _, [_, {:binary, _, nil}]} -> true
      _ -> false
    end)
  end

  defp interpolated_binary?(_), do: false
end
