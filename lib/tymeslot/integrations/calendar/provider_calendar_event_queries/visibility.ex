defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries.Visibility do
  @moduledoc """
  Turns a `Tymeslot.Integrations.Calendar.Selection.visibility_rules/1` map
  into the `where`-ready `Ecto.Query.dynamic/2` expression
  `ProviderCalendarEventQueries` applies, so calendar selection is filtered
  in SQL rather than after a capped fetch.

  Split out of the owning query module purely to keep it under Core's
  module-size limit; this is not a sanctioned entry point of its own;
  callers go through `ProviderCalendarEventQueries.search/3` and
  `.list_upcoming_timed/4`.
  """

  import Ecto.Query, warn: false

  @doc """
  Builds the `where`-ready dynamic that keeps a row when either its
  integration carries no rule in `rules` (unknown integrations are always
  kept, matching `Selection.visible_events/2`) or the rule for its
  integration says the row is visible. `rules == %{}` (the default for
  callers that don't filter by selection) short-circuits to "keep
  everything" without emitting the always-true `not in []` clause.
  """
  @spec dynamic_for(map()) :: Ecto.Query.dynamic_expr()
  def dynamic_for(rules) when rules == %{}, do: dynamic(true)

  def dynamic_for(rules) do
    known_ids = Map.keys(rules)

    per_integration =
      Enum.reduce(rules, dynamic(false), fn {integration_id, rule}, acc ->
        dynamic(
          [e],
          ^acc or (e.calendar_integration_id == ^integration_id and ^rule_dynamic(rule))
        )
      end)

    dynamic([e], e.calendar_integration_id not in ^known_ids or ^per_integration)
  end

  defp rule_dynamic(:all), do: dynamic(true)
  defp rule_dynamic(:none), do: dynamic(false)

  # Mirrors `Selection.calendar_for_event/2`: a CalDAV row (`provider_event_id`
  # is an href starting with `/`) is matched by path prefix against the
  # selected entries; every other row is matched by `provider_calendar_id`
  # equality. Both branches are boolean-safe (never NULL) so a row with a
  # NULL column is excluded outright rather than propagating NULL through
  # the combination below.
  defp rule_dynamic({:selected, entries}) do
    is_caldav = dynamic([e], not is_nil(e.provider_event_id) and like(e.provider_event_id, "/%"))

    dynamic(
      [e],
      (^is_caldav and ^caldav_prefix_dynamic(entries)) or
        (not (^is_caldav) and ^provider_calendar_id_dynamic(entries))
    )
  end

  defp caldav_prefix_dynamic(entries) do
    entries
    |> Enum.map(& &1.prefix)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&(escape_like(&1) <> "%"))
    |> Enum.reduce(dynamic(false), fn pattern, acc ->
      dynamic([e], ^acc or like(e.provider_event_id, ^pattern))
    end)
  end

  defp provider_calendar_id_dynamic(entries) do
    case entries |> Enum.map(& &1.id) |> Enum.reject(&is_nil/1) do
      [] -> dynamic(false)
      ids -> dynamic([e], not is_nil(e.provider_calendar_id) and e.provider_calendar_id in ^ids)
    end
  end

  # Escapes LIKE/ILIKE wildcard metacharacters so a CalDAV path prefix is
  # matched literally rather than as a pattern.
  defp escape_like(term) do
    String.replace(term, ~r/[\\%_]/, "\\\\\\0")
  end
end
