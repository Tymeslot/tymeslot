defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventSearchQueries do
  @moduledoc """
  Free-text search over a user's cached calendar events.

  `search/3` is the old calendar's search (earliest first); `search_around/3`
  is the new calendar's, nearest to a moment first: what is ahead in
  ascending order, then what has passed, latest first. Both match the term
  case-insensitively against `summary`, `description` and `location`, scoped
  to the user's active integrations, and leave out rows with half their
  timing. Moved out of `ProviderCalendarEventQueries`, which sits at Core's
  module-size limit.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries.Visibility
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  # Bound from the module that owns the column's vocabulary, as
  # `ProviderCalendarEventQueries` does, so a rename cannot leave a stale
  # literal in a `where` clause.
  @role_busy_only EventRole.busy_only()
  @sync_state_locally_deleted "locally_deleted"

  @default_search_limit 50
  @default_around_limit 20

  @doc """
  Searches a user's cached calendar events by a free-text term.

  Performs a case-insensitive `ILIKE` match against the event `summary`,
  `description`, and `location`. Results are scoped to the user's active
  calendar integrations and exclude any integration whose id appears in
  `:hidden_integration_ids`. Matches are ordered by start time ascending
  (timed events by `start_at`, all-day events by `start_date`) and capped
  at `:limit` (default #{@default_search_limit}).

  A blank or whitespace-only term returns `[]` without touching the database.

  ## Options

  - `:hidden_integration_ids`: list of integration ids to exclude (default `[]`).
  - `:limit`: maximum number of rows to return (default #{@default_search_limit}).
  - `:visibility_rules`: a map of `integration_id => Selection.visibility_rule/0`
    (see `Tymeslot.Integrations.Calendar.Selection.visibility_rules/1`), applied
    as a `where` clause so a deselected calendar's rows never occupy a limit
    slot a real match could have used. Omitted or `%{}` returns every row
    regardless of selection, matching the pre-selection behaviour.
  """
  @spec search(integer(), String.t(), keyword()) :: [ProviderCalendarEventSchema.t()]
  def search(user_id, term, opts \\ []) when is_integer(user_id) do
    case String.trim(to_string(term)) do
      "" ->
        []

      trimmed ->
        user_id
        |> matching(trimmed, opts)
        |> order_by([e, _i],
          asc: coalesce(e.start_at, type(e.start_date, :utc_datetime_usec)),
          asc: e.id
        )
        |> limit(^Keyword.get(opts, :limit, @default_search_limit))
        |> Repo.all()
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
  - `:hidden_integration_ids` and `:visibility_rules`: as `search/3`.
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
          upcoming:
            drawn
            |> where(
              [e, _i],
              coalesce(e.start_at, type(e.start_date, :utc_datetime_usec)) >=
                type(^from_utc, :utc_datetime_usec)
            )
            |> order_by([e, _i],
              asc: coalesce(e.start_at, type(e.start_date, :utc_datetime_usec)),
              asc: e.id
            )
            |> limit(^limit)
            |> Repo.all(),
          past:
            drawn
            |> where(
              [e, _i],
              coalesce(e.start_at, type(e.start_date, :utc_datetime_usec)) <
                type(^from_utc, :utc_datetime_usec)
            )
            |> order_by([e, _i],
              desc: coalesce(e.start_at, type(e.start_date, :utc_datetime_usec)),
              desc: e.id
            )
            |> limit(^limit)
            |> Repo.all()
        }
    end
  end

  # The term, scope and visibility clauses both searches share.
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
