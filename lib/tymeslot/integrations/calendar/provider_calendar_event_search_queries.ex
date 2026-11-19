defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventSearchQueries do
  @moduledoc """
  Free-text search over a user's cached calendar events.

  `search_around/3` is the calendar's command bar search, nearest to a
  moment first: what is ahead in ascending order, then what has passed,
  latest first. It matches the term case-insensitively against `summary`,
  `description` and `location`, scoped to the user's active integrations,
  and leaves out rows with half their timing.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries.Visibility
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Repo

  # Bound from the module that owns the column's vocabulary, as
  # `ProviderCalendarEventQueries` does, so a rename cannot leave a stale
  # literal in a `where` clause.
  @role_busy_only EventRole.busy_only()
  @sync_state_locally_deleted "locally_deleted"

  @default_around_limit 20

  # The key a series' occurrences share, mirroring `Occurrence.series_address/1`:
  # an OAuth occurrence names its master (`recurring_event_id`), a master its
  # own id; a CalDAV-family member is part of the resource its href names;
  # anything else stands alone.
  defmacrop series_key(e, resource, oauth) do
    quote do
      fragment(
        """
        CASE
          WHEN ? = ANY(?) AND COALESCE(?, '') <> '' THEN 'm:' || ?
          WHEN ? = ANY(?) AND COALESCE(?, '') <> '' AND COALESCE(?, '') <> '' THEN 'm:' || ?
          WHEN ? = ANY(?) AND (COALESCE(?, '') <> '' OR COALESCE(?, '') <> '')
               AND COALESCE(?, '') <> '' THEN 'r:' || ?
          ELSE 'row:' || ?::text
        END
        """,
        unquote(e).provider,
        unquote(oauth),
        unquote(e).recurring_event_id,
        unquote(e).recurring_event_id,
        unquote(e).provider,
        unquote(oauth),
        unquote(e).recurrence_rule,
        unquote(e).provider_event_id,
        unquote(e).provider_event_id,
        unquote(e).provider,
        unquote(resource),
        unquote(e).recurring_event_id,
        unquote(e).recurrence_rule,
        unquote(e).provider_event_id,
        unquote(e).provider_event_id,
        unquote(e).id
      )
    end
  end

  @doc """
  Searches a user's cached calendar events around a moment: the matches
  starting on or after `:from` in ascending order (`upcoming`), and those
  starting before it, latest first (`past`). Each side is capped at `:limit`.
  Busy time with nothing to show and rows deleted locally are left out, as
  the grid never draws them. A blank term returns empty sides without a
  query.

  ## Options

  - `:from` (required): the moment the two sides divide at.
  - `:limit`: rows per side (default #{@default_around_limit}).
  - `:hidden_integration_ids`: integration ids to leave out (default `[]`).
  - `:visibility_rules`: a map of `integration_id => Selection.visibility_rule/0`
    (see `Tymeslot.Integrations.Calendar.Selection.visibility_rules/1`), applied
    as a `where` clause so a deselected calendar's rows never occupy a limit
    slot a real match could have used. Omitted or `%{}` returns every row
    regardless of selection.
  """
  @spec search_around(integer(), String.t(), keyword()) :: %{
          upcoming: [ProviderCalendarEventSchema.t()],
          past: [ProviderCalendarEventSchema.t()]
        }
  def search_around(user_id, term, opts) when is_integer(user_id) do
    case String.trim(to_string(term)) do
      "" ->
        %{upcoming: [], past: []}

      trimmed ->
        from_utc = Keyword.fetch!(opts, :from)
        limit = Keyword.get(opts, :limit, @default_around_limit)

        drawn =
          user_id
          |> matching(trimmed, opts)
          |> where(
            [e, _i],
            e.role != ^@role_busy_only and e.sync_state != ^@sync_state_locally_deleted
          )

        %{
          upcoming: nearest_per_series(drawn, :upcoming, from_utc, limit),
          past: nearest_per_series(drawn, :past, from_utc, limit)
        }
    end
  end

  # One row per repeating series (the row nearest `from_utc` on that side),
  # taken before the limit so a daily series cannot fill the page and crowd
  # out other matches.
  defp nearest_per_series(drawn, :upcoming, from_utc, limit) do
    {resource, oauth} = series_providers()

    ranked =
      drawn
      |> where(
        [e, _i],
        coalesce(e.start_at, type(e.start_date, :utc_datetime_usec)) >=
          type(^from_utc, :utc_datetime_usec)
      )
      |> select([e, _i], %{
        id: e.id,
        rn:
          over(row_number(),
            partition_by: [
              e.calendar_integration_id,
              series_key(e, type(^resource, {:array, :string}), type(^oauth, {:array, :string}))
            ],
            order_by: [
              asc: coalesce(e.start_at, type(e.start_date, :utc_datetime_usec)),
              asc: e.id
            ]
          )
      })

    ProviderCalendarEventSchema
    |> join(:inner, [e], r in subquery(ranked), on: r.id == e.id and r.rn == 1)
    |> order_by([e], asc: coalesce(e.start_at, type(e.start_date, :utc_datetime_usec)), asc: e.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp nearest_per_series(drawn, :past, from_utc, limit) do
    {resource, oauth} = series_providers()

    ranked =
      drawn
      |> where(
        [e, _i],
        coalesce(e.start_at, type(e.start_date, :utc_datetime_usec)) <
          type(^from_utc, :utc_datetime_usec)
      )
      |> select([e, _i], %{
        id: e.id,
        rn:
          over(row_number(),
            partition_by: [
              e.calendar_integration_id,
              series_key(e, type(^resource, {:array, :string}), type(^oauth, {:array, :string}))
            ],
            order_by: [
              desc: coalesce(e.start_at, type(e.start_date, :utc_datetime_usec)),
              desc: e.id
            ]
          )
      })

    ProviderCalendarEventSchema
    |> join(:inner, [e], r in subquery(ranked), on: r.id == e.id and r.rn == 1)
    |> order_by([e],
      desc: coalesce(e.start_at, type(e.start_date, :utc_datetime_usec)),
      desc: e.id
    )
    |> limit(^limit)
    |> Repo.all()
  end

  # The providers each family of series addressing applies to, as stored
  # strings: `{resource family (CalDAV and debug), OAuth family}`.
  defp series_providers do
    oauth =
      for p <- ProviderConfig.all_providers_with_dev(),
          ProviderConfig.oauth_provider?(p),
          do: Atom.to_string(p)

    {ProviderConfig.caldav_based_provider_strings() ++ ["debug"], oauth}
  end

  # The term, scope and visibility clauses of the search.
  defp matching(user_id, trimmed, opts) do
    hidden_ids = Keyword.get(opts, :hidden_integration_ids, [])
    rules = Keyword.get(opts, :visibility_rules, %{})
    pattern = "%" <> escape_like(trimmed) <> "%"

    ProviderCalendarEventSchema
    |> join(:inner, [e], i in assoc(e, :calendar_integration))
    |> where([_e, i], i.user_id == ^user_id and i.is_active == true)
    |> where([e, _i], e.calendar_integration_id not in ^hidden_ids)
    |> where(
      [e, _i],
      ilike(e.summary, ^pattern) or ilike(e.description, ^pattern) or
        ilike(e.location, ^pattern)
    )
    |> where([e, _i], ^Visibility.dynamic_for(rules))
    # A row with half its timing (stored before the cache's writers checked
    # it) has nowhere to be shown; leaving it out here, rather than after
    # the limit, keeps a page of results full.
    |> where(
      [e, _i],
      (e.all_day == true and not is_nil(e.start_date) and not is_nil(e.end_date)) or
        (e.all_day == false and not is_nil(e.start_at) and not is_nil(e.end_at))
    )
  end

  # Escapes LIKE/ILIKE wildcard metacharacters so a user-typed term is matched
  # literally rather than as a pattern.
  defp escape_like(term) do
    String.replace(term, ~r/[\\%_]/, "\\\\\\0")
  end
end
