defmodule Tymeslot.CalendarGrid.SeriesCarry do
  @moduledoc """
  Carries what only Tymeslot knows about a recurring series across a write
  that drops the series' cached rows for a sync to bring back: an edit of
  every occurrence, a split for an edit of one occurrence and every following
  one (`Tymeslot.CalendarGrid.SeriesEdit`), and a move of the whole series to
  another calendar (`Tymeslot.CalendarGrid.SeriesTransfer`). A series just
  created from the grid is carried the same way into its first sync.

  Two things about a series live in Tymeslot alone:

    * its video, the `video_link` and `video_integration_id` of its rows. No
      sync writes them: `ProviderCalendarEventQueries.replace_fields/0` leaves
      them out, so that a row the sync updates keeps them, but a row the sync
      inserts has none;
    * the organiser's colour overrides (`Calendar.set_event_colour/3`), each
      keyed by the uid one occurrence is cached under.

  `plan/3` reads both from the series' rows, and so runs before they are
  deleted; `carry/1` writes them once they are. A write that has reached the
  calendar cannot be undone, so neither step may fail it: each is rescued
  and logged, and a plan that could not be read carries nothing.

  ## The series' video

  What is carried is the series' own video: the one on the row the grid
  caches for the series as a whole (its master's row, or a CalDAV row under
  the series' own UID), otherwise the one more than half of its rows carry.
  A video one occurrence was given on its own is not spread to the rest of
  the series. The video goes to every part of the series as the write left
  it: the series itself after an edit of every occurrence, both halves of a
  split, and the series on the calendar it moved to.

  The sync that brings the series back runs on its own, so the video cannot
  be written onto its rows yet, and their uids are not all known. It is
  handed to `Tymeslot.Workers.SeriesVideoWorker`, which waits until a sync
  has cached occurrences of the series where it now lives and gives every
  one without a video of its own the series' (see
  `ProviderCalendarSeriesQueries.put_video/5`). From then on they keep it,
  as every row keeps its video through a sync.

  A Teams meeting switched on for an Outlook event itself stays with the
  event it was made for: an Outlook series moved to another calendar is a
  copy without it (see `SeriesTransfer`), so its link is not carried there.

  ## Colour overrides

  An override is moved to the uid its occurrence will be cached under,
  which is derived from the uid it had, how far the series moved, and the
  uid of the series it now belongs to, never from a later read of the cache,
  which does not hold the new rows yet. Google and the CalDAV family cache an
  occurrence under its series' UID and a stamp of the slot the series put it
  in: Google `<UID>_<original start in UTC>`, CalDAV `<UID>_<start on the
  series' wall clock>`, or a date for an all-day series. A move of the series
  moves every slot by as much on the series' wall clock, and a split or a
  move to another calendar gives the occurrences a series of their own, so:

    * after an edit of every occurrence that moved it, each stamp moves as
      the series did;
    * after a split, the occurrences from the edited one on take the new
      series' UID, their stamps moved as the edit moved the occurrence; the
      earlier ones keep theirs;
    * after a move to another calendar, every occurrence takes the new
      series' UID on the integration it moved to.

  An occurrence whose uid carries no stamp has nothing to follow it by.
  Outlook caches every occurrence under an iCalendar UID of its own, which a
  moved or copied series replaces, so an override on an Outlook occurrence is
  kept only where its occurrence keeps its uid (an edit that does not move
  the series, or the earlier half of a split), and is otherwise deleted, as
  one on any other occurrence with no successor is. An override whose moved
  key names an occurrence the series no longer has matches nothing, as it
  would have after any other change to the series outside the grid.
  """

  require Logger

  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.Integrations.Calendar.ColourOverrideQueries
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Shift
  alias Tymeslot.Integrations.Calendar.ProviderCalendarSeriesQueries
  alias Tymeslot.Integrations.MeetingProvisioning
  alias Tymeslot.Utils.MapKeys
  alias Tymeslot.Workers.SeriesVideoWorker

  @day 86_400

  # An occurrence's uid: its series' UID, an underscore, and the stamp of its
  # slot (a date, or a date-time on a wall clock or in UTC).
  @stamped ~r/\A(.+)_(\d{8}(?:T\d{6}Z?)?)\z/

  @typedoc """
  Where a series lives: its integration, its address there
  (`Occurrence.series_address/0`), and its UID, the prefix of its
  occurrences' uids (`nil` where they carry none).
  """
  @type series :: %{
          integration_id: pos_integer(),
          address: Occurrence.series_address(),
          uid: String.t() | nil
        }

  @typedoc """
  The write the series took:

    * `{:edited, changes}` - every occurrence took `changes`, in the cache's
      vocabulary.
    * `{:split, changes, tail}` - the occurrences from the edited one on
      took `changes` as a new series, `tail`, which the provider addresses
      as `:id` (a CalDAV resource's href, a Google or Outlook master's id)
      and whose UID is `:uid`.
    * `{:moved, integration_id, written}` - the whole series was written to
      the integration `integration_id`, as `SeriesTransfer` describes it
      (`:uid` and `:id`).
  """
  @type write ::
          {:edited, map()}
          | {:split, map(), %{uid: String.t(), id: String.t()}}
          | {:moved, pos_integer(), %{uid: String.t(), id: String.t()}}

  @typedoc "What `carry/1` writes."
  @opaque plan :: %{
            user_id: pos_integer(),
            colour_moves: [{{pos_integer(), String.t()}, {pos_integer(), String.t()} | nil}],
            video: {pos_integer(), String.t()} | nil,
            video_to: [series()]
          }

  @doc """
  Reads what `write` of the series `stored` (the cached row of one of its
  members, as it was before the write) leaves to carry, before its rows are
  deleted.
  """
  @spec plan(pos_integer(), map(), write()) :: plan()
  def plan(user_id, stored, write) do
    case Occurrence.series_address(stored) do
      {:ok, address} ->
        build_plan(user_id, stored, write, address)

      {:error, _unaddressable} ->
        nothing(user_id)
    end
  rescue
    error ->
      log_failure("read what the series carries", user_id, stored, error, __STACKTRACE__)
      nothing(user_id)
  end

  defp build_plan(user_id, stored, write, address) do
    source = %{
      integration_id: stored.calendar_integration_id,
      address: address,
      uid: series_uid(stored, address)
    }

    rows = ProviderCalendarSeriesQueries.list_rows(source.integration_id, address)
    parts = parts(stored, source, rows, write)

    %{
      user_id: user_id,
      colour_moves: colour_moves(source, parts, stamps(stored)),
      video: carried_video(user_id, stored, source, rows, write),
      video_to: for({part_rows, series, _shift} <- parts, part_rows != [], do: series)
    }
  end

  @doc """
  Writes what `plan` carries: moves the colour overrides, and hands the
  series' video to `Tymeslot.Workers.SeriesVideoWorker` for each series it
  goes to. Always `:ok`; a failure is logged.
  """
  @spec carry(plan()) :: :ok
  def carry(%{user_id: user_id} = plan) do
    step("move the series' colour overrides", user_id, fn ->
      ColourOverrideQueries.move_external(user_id, plan.colour_moves)
    end)

    step("hand over the series' video", user_id, fn ->
      if plan.video, do: Enum.each(plan.video_to, &SeriesVideoWorker.enqueue(&1, plan.video))
    end)
  end

  @doc """
  Hands the video of a series just created from the grid to its first sync,
  which caches its occurrences without one. `created` is the row the grid
  caches for the series, with its `:provider` and `:provider_event_id` as the
  provider answered the create; nothing is carried for an event outside a
  series, one without a video, or one whose provider cannot be addressed.
  """
  @spec series_created(map()) :: :ok
  def series_created(
        %{video_link: link, video_integration_id: video_id, recurrence_rule: rule} = created
      )
      when is_binary(link) and link != "" and is_integer(video_id) and is_binary(rule) and
             rule != "" do
    case Occurrence.series_address(created) do
      {:ok, address} ->
        series = %{
          integration_id: created.calendar_integration_id,
          address: address,
          uid: created.uid
        }

        step("hand over the created series' video", nil, fn ->
          SeriesVideoWorker.enqueue(series, {video_id, link})
        end)

      {:error, :unaddressable_series} ->
        :ok
    end
  end

  def series_created(_created), do: :ok

  @doc """
  Gives the occurrences of `series` cached so far the video `video` where
  they have none; see `ProviderCalendarSeriesQueries.put_video/5`. Returns
  `:not_cached` while no sync has cached any occurrence of the series.
  Unscoped, for `Tymeslot.Workers.SeriesVideoWorker` alone.
  """
  @spec put_video(series(), {pos_integer(), String.t()}) :: :ok | :not_cached
  def put_video(series, {video_integration_id, video_link}) do
    case ProviderCalendarSeriesQueries.put_video(
           series.integration_id,
           series.address,
           series.uid,
           video_integration_id,
           video_link
         ) do
      {:ok, _count} -> :ok
      :not_cached -> :not_cached
    end
  end

  defp nothing(user_id), do: %{user_id: user_id, colour_moves: [], video: nil, video_to: []}

  # The rows each series the write left takes, with that series and how far
  # the write moved their slots (`:unknown` when it could not be read).
  defp parts(stored, source, rows, {:edited, changes}),
    do: [{rows, source, shift(stored, changes)}]

  defp parts(stored, source, rows, {:split, changes, tail}) do
    {tail_rows, head_rows} = Enum.split_with(rows, &from_slot?(&1, stored))

    [
      {head_rows, source, 0},
      {tail_rows, %{source | address: retarget(source.address, tail.id), uid: tail.uid},
       shift(stored, changes)}
    ]
  end

  defp parts(_stored, source, rows, {:moved, integration_id, written}) do
    series = %{
      integration_id: integration_id,
      address: retarget(source.address, written.id),
      uid: written.uid
    }

    [{rows, series, 0}]
  end

  defp retarget({kind, _id}, id), do: {kind, id}

  defp colour_moves(source, parts, stamps) do
    Enum.flat_map(parts, fn {rows, series, shift} ->
      rows
      |> Enum.map(
        &{{source.integration_id, &1.uid}, successor(&1.uid, source, series, shift, stamps)}
      )
      |> Enum.reject(fn {from, to} -> from == to end)
    end)
  end

  # How the series' occurrences' uids stamp their slots: in the series' zone
  # (`{:stamped, zone}`) for Google and the CalDAV family, and not at all for
  # Outlook, whose occurrences carry iCalendar UIDs of their own.
  defp stamps(stored) do
    if to_string(stored.provider) == "outlook", do: :unstamped, else: {:stamped, zone(stored)}
  end

  # The uid the occurrence cached as `uid` has in `series`, which it moved to
  # from `source` with its slot moved by `shift`: the same where neither
  # changed, and otherwise its series' UID with its stamp moved.
  defp successor(uid, %{integration_id: id, address: address}, series, 0, _stamps)
       when series.integration_id == id and series.address == address,
       do: {id, uid}

  defp successor(uid, source, series, shift, {:stamped, zone}) do
    with [_uid, prefix, stamp] <- Regex.run(@stamped, uid),
         true <- is_integer(shift),
         {:ok, moved} <- move_stamp(stamp, shift, zone) do
      new_prefix = if series.address == source.address, do: prefix, else: series.uid
      {series.integration_id, "#{new_prefix}_#{moved}"}
    else
      _no_successor -> nil
    end
  end

  defp successor(_uid, _source, _series, _shift, :unstamped), do: nil

  defp move_stamp(stamp, 0, _zone), do: {:ok, stamp}
  defp move_stamp(stamp, shift, zone), do: Shift.shift_bound(stamp, shift, div(shift, @day), zone)

  # Whether `row` is the edited occurrence or one after it, by the slot the
  # series put each in. Kept with the earlier half when that cannot be told.
  defp from_slot?(row, stored) do
    case {slot(row), slot(stored)} do
      {{:stamp, own}, {:stamp, edited}} ->
        own >= edited

      {{:start, %DateTime{} = own}, {:start, %DateTime{} = edited}} ->
        DateTime.compare(own, edited) != :lt

      {{:start, %Date{} = own}, {:start, %Date{} = edited}} ->
        Date.compare(own, edited) != :lt

      _unknown ->
        false
    end
  end

  defp slot(row) do
    case Regex.run(@stamped, row.uid) do
      [_uid, _prefix, stamp] -> {:stamp, stamp}
      nil -> original_start(row)
    end
  end

  defp original_start(row) do
    case Occurrence.original_start(row) do
      {:ok, start} -> {:start, start}
      {:error, _unaddressable} -> :unknown
    end
  end

  # How far the edit moved the occurrence, and every slot of the series with
  # it, on the wall clock of the series' zone: whole days for an all-day
  # series.
  defp shift(%{all_day: true, start_date: %Date{} = from}, changes) do
    case Map.get(changes, :start_date, from) do
      %Date{} = to -> Date.diff(to, from) * @day
      _unreadable -> :unknown
    end
  end

  defp shift(%{start_at: %DateTime{} = from} = stored, changes) do
    with %DateTime{} = to <- Map.get(changes, :start_at, from),
         {:ok, to} <- Shift.wall_of(to, zone(stored)),
         {:ok, from} <- Shift.wall_of(from, zone(stored)) do
      NaiveDateTime.diff(to, from)
    else
      _unreadable -> :unknown
    end
  end

  defp shift(_stored, _changes), do: :unknown

  defp zone(stored) do
    case Map.get(stored, :timezone) do
      zone when is_binary(zone) and zone != "" -> zone
      _none -> "Etc/UTC"
    end
  end

  # The prefix of the series' occurrences' uids: the CalDAV UID the sync
  # records, or the uid's own prefix, or the uid itself for the row cached
  # under the series' UID.
  defp series_uid(stored, address) do
    metadata_uid = MapKeys.get_binary(Map.get(stored, :provider_metadata), :uid)

    cond do
      is_binary(metadata_uid) and metadata_uid != "" -> metadata_uid
      match?([_uid, _prefix, _stamp], Regex.run(@stamped, stored.uid)) -> stamp_prefix(stored.uid)
      match?({:resource, _href}, address) -> stored.uid
      true -> nil
    end
  end

  defp stamp_prefix(uid), do: @stamped |> Regex.run(uid) |> Enum.at(1)

  defp carried_video(user_id, stored, source, rows, write) do
    video = series_video(rows, source)
    if video && carried?(user_id, stored, video, write), do: video, else: nil
  end

  # The video the row standing for the whole series carries, or else the one
  # more than half of the series' rows carry.
  defp series_video(rows, source) do
    case Enum.find(rows, &whole_series_row?(&1, source)) do
      %{video_link: link, video_integration_id: id} when is_binary(link) and is_integer(id) ->
        {id, link}

      _none ->
        rows
        |> Enum.map(&video/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()
        |> Enum.find_value(fn {video, count} -> if count * 2 > length(rows), do: video end)
    end
  end

  defp whole_series_row?(row, %{address: {:master, master_id}}),
    do: row.provider_event_id == master_id and row.recurring_event_id in [nil, ""]

  defp whole_series_row?(row, %{address: {:resource, _href}, uid: uid}), do: row.uid == uid

  defp video(%{video_link: link, video_integration_id: id})
       when is_binary(link) and link != "" and is_integer(id),
       do: {id, link}

  defp video(_row), do: nil

  # An Outlook series moved to another calendar is a copy, which a Teams
  # meeting switched on for the original does not follow. A Teams meeting
  # held as an Outlook event of its own is recorded, and its link travels in
  # the description.
  defp carried?(user_id, stored, {video_id, _link}, {:moved, _integration_id, _written}) do
    not (to_string(stored.provider) == "outlook" and
           match?(
             {:attach, _video_id},
             MeetingProvisioning.plan(stored.calendar_integration_id, video_id, user_id)
           ) and EventVideoRooms.rooms_on_integration(stored, video_id) == [])
  end

  defp carried?(_user_id, _stored, _video, _write), do: true

  defp step(step, user_id, fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.error("Calendar grid: could not carry a series' state across a write",
        step: step,
        user_id: user_id,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  defp log_failure(step, user_id, stored, error, stacktrace) do
    Logger.error("Calendar grid: could not carry a series' state across a write",
      step: step,
      user_id: user_id,
      calendar_integration_id: Map.get(stored, :calendar_integration_id),
      error: Exception.format(:error, error, stacktrace)
    )
  end
end
