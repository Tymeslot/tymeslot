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
      Logger.debug(fn -> "Slow query took \#{ms}ms" end)

      # Good — static message, variable data in keyword metadata
      Logger.info("Meeting created", meeting_id: meeting.id, user_id: user_id)
      Logger.error("OAuth failed", operation: operation, reason: inspect(reason))
      Logger.debug(fn -> "Slow query" end)
  """

  use Credo.Check,
    base_priority: :low,
    category: :design,
    explanations: [
      check: """
      Logger message contains string interpolation. Move dynamic data to keyword
      metadata instead so log lines are stable and queryable in aggregation systems.
      This applies to both direct messages and lazy function forms.

      Bad:
          Logger.info("Meeting \#{id} created by user \#{user_id}")
          Logger.debug(fn -> "Slow query took \#{ms}ms" end)

      Good:
          Logger.info("Meeting created", meeting_id: id, user_id: user_id)
          Logger.debug(fn -> "Slow query" end)
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
  # Logger.level(fn -> "interpolated #{message}" end)
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Logger]}, level]}, meta, [message | _]} = ast,
         issues,
         issue_meta
       )
       when level in @logger_levels do
    if interpolated_message?(message) do
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

  # Unwrap lazy function form: fn -> body end — check if the body contains interpolation.
  # A single-expression body has the form {:fn, _, [{:->, _, [[], expr]}]}.
  # A multi-expression body has the form {:fn, _, [{:->, _, [[], {:__block__, _, exprs}]}]}.
  defp interpolated_message?({:fn, _, [{:->, _, [[], body]}]}) do
    body
    |> body_expressions()
    |> Enum.any?(&interpolated_binary?/1)
  end

  defp interpolated_message?(node), do: interpolated_binary?(node)

  defp body_expressions({:__block__, _, exprs}), do: exprs
  defp body_expressions(expr), do: [expr]

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
