defmodule Tymeslot.Integrations.Calendar.ProviderCalendarSeriesQueries do
  @moduledoc """
  Database queries over every cached row of one recurring series.

  A series is addressed as its provider addresses it: a Google or Outlook
  series by its master's id (`{:master, id}`), which its occurrences name in
  `recurring_event_id` and the master's own row, when cached, carries as its
  `provider_event_id`; a CalDAV series by the href of the resource holding it
  (`{:resource, href}`), which every row of it carries as its
  `provider_event_id`. The per-row queries stay in
  `ProviderCalendarEventQueries`.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries.Visibility
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo

  @typedoc "How a provider addresses a whole series."
  @type address :: {:master, String.t()} | {:resource, String.t()}

  @doc """
  Every cached row of the series at `address` in the integration
  `calendar_integration_id`: a master's occurrences and its own row, or every
  row of a CalDAV resource.
  """
  @spec list_rows(integer(), address()) :: [ProviderCalendarEventSchema.t()]
  def list_rows(calendar_integration_id, {:master, master_id}) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where([e], e.recurring_event_id == ^master_id or e.provider_event_id == ^master_id)
    |> Repo.all()
  end

  def list_rows(calendar_integration_id, {:resource, href}) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where([e], e.provider_event_id == ^href)
    |> Repo.all()
  end

  @doc """
  The videos the rows cached for the masters `master_ids` themselves carry,
  in the integration `calendar_integration_id`: `{master_id,
  video_integration_id, video_link}` for each master row with both a video
  integration and a link.
  """
  @spec list_master_videos(integer(), [String.t()]) ::
          [{String.t(), pos_integer(), String.t()}]
  def list_master_videos(_calendar_integration_id, []), do: []

  def list_master_videos(calendar_integration_id, master_ids) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where([e], e.provider_event_id in ^master_ids)
    |> where([e], is_nil(e.recurring_event_id) or e.recurring_event_id == "")
    |> where([e], not is_nil(e.video_integration_id) and e.video_link != "")
    |> select([e], {e.provider_event_id, e.video_integration_id, e.video_link})
    |> Repo.all()
  end

  @doc """
  The rows of the integrations `integration_ids` that stand in for a whole
  series no sync has cached the occurrences of yet, starting before
  `range_end`, each with the user owning its integration: `{row, user_id}`.

  A stand-in is the row the calendar caches for a series it has just
  written, or for an event it has just given a repeat rule: a rule, and the
  row's own UID rather than an occurrence's (a CalDAV occurrence keeps its
  series' UID in `provider_metadata`, a Google or Outlook one names its
  master in `recurring_event_id`). It stops being one as soon as an
  occurrence of its series is cached: a row under its UID and a slot's key,
  one in the same CalDAV resource, or one naming it as its master. Only providers the calendar writes repeat
  rules to (`providers`) are read, so an Exchange master, which stands for a
  series the item path could not expand, is never taken for one. A row
  waiting for its delete to be sent is left out.

  ## Options

    * `:visibility_rules` - as `ProviderCalendarEventQueries.list_upcoming_timed/4`
      takes them; `%{}` (the default) keeps every calendar.
    * `:except_role` - a `role` to leave out.
  """
  @spec list_unsynced_series([integer()], DateTime.t(), [String.t()], keyword()) ::
          [{ProviderCalendarEventSchema.t(), pos_integer()}]
  def list_unsynced_series(integration_ids, range_end, providers, opts \\ [])

  def list_unsynced_series([], _range_end, _providers, _opts), do: []

  def list_unsynced_series(integration_ids, %DateTime{} = range_end, providers, opts) do
    range_end_date = DateTime.to_date(range_end)

    from(e in ProviderCalendarEventSchema, as: :stand_in)
    |> join(:inner, [e], i in CalendarIntegrationSchema, on: i.id == e.calendar_integration_id)
    |> where([e], e.calendar_integration_id in ^integration_ids and e.provider in ^providers)
    |> where([e], not is_nil(e.recurrence_rule) and e.recurrence_rule != "")
    |> where([e], is_nil(e.recurring_event_id) or e.recurring_event_id == "")
    |> where([e], fragment("coalesce(?->>'uid', ?) = ?", e.provider_metadata, e.uid, e.uid))
    |> where([e], e.sync_state != "locally_deleted")
    |> where(
      [e],
      (e.all_day == false and e.start_at < ^range_end) or
        (e.all_day == true and e.start_date <= ^range_end_date)
    )
    |> where([e], ^Visibility.dynamic_for(Keyword.get(opts, :visibility_rules, %{})))
    |> except_role(Keyword.get(opts, :except_role))
    |> where(
      [e],
      not exists(
        from(o in ProviderCalendarEventSchema,
          where:
            o.calendar_integration_id == parent_as(:stand_in).calendar_integration_id and
              o.id != parent_as(:stand_in).id and
              (o.recurring_event_id == parent_as(:stand_in).provider_event_id or
                 o.provider_event_id == parent_as(:stand_in).provider_event_id or
                 fragment(
                   "starts_with(?, ? || '_')",
                   o.uid,
                   parent_as(:stand_in).uid
                 ))
        )
      )
    )
    |> select([e, i], {e, i.user_id})
    |> Repo.all()
  end

  defp except_role(query, nil), do: query
  defp except_role(query, role), do: where(query, [e], e.role != ^role)

  @doc """
  The most recently synced occurrence of the CalDAV series `series_uid` in
  the integration `calendar_integration_id` that carries its resource's
  document: every occurrence is cached with the resource's `raw_ical`, ETag
  and href, under the series' UID and a slot's key. `provider_calendar_id`,
  when given, keeps to that calendar of the integration. `{:error,
  :not_found}` when none is cached.
  """
  @spec get_resource_occurrence(integer(), String.t(), String.t() | nil) ::
          {:ok, ProviderCalendarEventSchema.t()} | {:error, :not_found}
  def get_resource_occurrence(calendar_integration_id, series_uid, provider_calendar_id \\ nil) do
    row =
      ProviderCalendarEventSchema
      |> where([e], e.calendar_integration_id == ^calendar_integration_id)
      |> in_calendar(provider_calendar_id)
      |> where([e], fragment("?->>'uid' = ?", e.provider_metadata, ^series_uid))
      |> where([e], e.uid != ^series_uid)
      |> where([e], not is_nil(e.raw_ical) and e.raw_ical != "")
      |> order_by([e], desc: e.synced_at, desc: e.id)
      |> limit(1)
      |> Repo.one()

    if row, do: {:ok, row}, else: {:error, :not_found}
  end

  defp in_calendar(query, calendar_id) when is_binary(calendar_id) and calendar_id != "",
    do: where(query, [e], e.provider_calendar_id == ^calendar_id)

  defp in_calendar(query, _any_calendar), do: query

  @doc """
  The videos the rows cached under the CalDAV series UIDs `series_uids`
  themselves carry, in the integration `calendar_integration_id`: `{uid,
  video_integration_id, video_link}` for each such row with both a video
  integration and a link. Those rows stand in for a whole series until a
  sync caches its occurrences.
  """
  @spec list_series_row_videos(integer(), [String.t()]) ::
          [{String.t(), pos_integer(), String.t()}]
  def list_series_row_videos(_calendar_integration_id, []), do: []

  def list_series_row_videos(calendar_integration_id, series_uids) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where([e], e.uid in ^series_uids)
    |> where([e], not is_nil(e.video_integration_id) and e.video_link != "")
    |> select([e], {e.uid, e.video_integration_id, e.video_link})
    |> Repo.all()
  end

  @doc """
  Gives every cached occurrence of the series at `address` that has no video
  of its own the link `video_link` from the video integration
  `video_integration_id`.

  An occurrence is a row a sync cached for one slot of the series, not a row
  standing in for the whole of it: a Google or Outlook row naming the master,
  or a CalDAV row of the resource other than one cached under the series' own
  UID, `series_uid`. A row with a link, or with an integration and no link
  yet, keeps what it has.

  Returns `{:ok, count}`, or `:not_cached` when the cache holds no occurrence
  of the series at all. Nothing is written when the video integration no
  longer exists.
  """
  @spec put_video(integer(), address(), String.t() | nil, pos_integer(), String.t()) ::
          {:ok, non_neg_integer()} | :not_cached
  def put_video(calendar_integration_id, address, series_uid, video_integration_id, video_link) do
    occurrences = occurrences(calendar_integration_id, address, series_uid)

    if Repo.exists?(occurrences) do
      {count, _rows} =
        occurrences
        |> where([e], is_nil(e.video_link) and is_nil(e.video_integration_id))
        |> where(
          [_e],
          exists(from(v in VideoIntegrationSchema, where: v.id == ^video_integration_id))
        )
        |> Repo.update_all(
          set: [
            video_link: video_link,
            video_integration_id: video_integration_id,
            updated_at: DateTime.utc_now(:microsecond)
          ]
        )

      {:ok, count}
    else
      :not_cached
    end
  end

  defp occurrences(calendar_integration_id, {:master, master_id}, _series_uid) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where([e], e.recurring_event_id == ^master_id)
  end

  defp occurrences(calendar_integration_id, {:resource, href}, series_uid) do
    query =
      ProviderCalendarEventSchema
      |> where([e], e.calendar_integration_id == ^calendar_integration_id)
      |> where([e], e.provider_event_id == ^href)

    if is_binary(series_uid), do: where(query, [e], e.uid != ^series_uid), else: query
  end

  @doc """
  Gives every cached occurrence of the Google or Outlook series `master_id`
  the series' rule as last read, or none when it was found to be gone or not
  a series. The master's own row is not an occurrence and keeps its rule.
  Answers how many rows were updated.
  """
  @spec put_occurrence_rule(integer(), String.t(), String.t() | nil) :: non_neg_integer()
  def put_occurrence_rule(calendar_integration_id, master_id, rule) do
    {count, _rows} =
      ProviderCalendarEventSchema
      |> where([e], e.calendar_integration_id == ^calendar_integration_id)
      |> where([e], e.recurring_event_id == ^master_id)
      |> Repo.update_all(set: [recurrence_rule: rule])

    count
  end

  @doc """
  The raw Graph event (`provider_metadata`) of every cached Outlook
  occurrence of the integration still held as `calendarView/delta` listed
  it, a stub without the fields its master completes it with, leaving out
  the rows whose `provider_event_id` is in `except`.
  """
  @spec list_unresolved_outlook_stubs(integer(), [String.t()]) :: [map()]
  def list_unresolved_outlook_stubs(calendar_integration_id, except) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where([e], e.provider == "outlook" and not is_nil(e.recurring_event_id))
    |> where([e], e.provider_event_id not in ^except)
    |> where([e], fragment("?->>'type' = 'occurrence'", e.provider_metadata))
    |> where([e], fragment("(?->'isAllDay') IS NULL", e.provider_metadata))
    |> select([e], e.provider_metadata)
    |> Repo.all()
  end
end
