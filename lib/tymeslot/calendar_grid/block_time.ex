defmodule Tymeslot.CalendarGrid.BlockTime do
  @moduledoc """
  "Block this time" from the calendar: guests can no longer book a stretch,
  without the organiser opening their schedule.

  With a writable calendar that blocks availability, the block is an
  ordinary busy event on the default one of them, picked by the ladder new
  bookings use (`Calendar.default_booking_calendar/2`), integration by
  integration. It is written through `NewEvent.create/2`, so it is cached at
  once, shows on every calendar the organiser uses and drops the booking
  page's cache. With no such calendar (none connected, or only read-only,
  subscribed or show-only ones) it is a part-day time off period, which the
  booking page honours with no calendar at all.

  A failed event write is reported as it is, and one queued for a retry as
  `{:error, {:queued, reason}}`; neither falls back to time off, which would
  block the time twice once the write lands. A write that succeeds but leaves
  no cached row is `{:error, :not_cached}`. `unblock/2` takes either kind
  back, for undo; a delete queued for a retry is `{:error, {:queued, reason}}`,
  and an event whose start, end or title has changed since the block is left
  alone as `{:error, :changed}`: it is no longer the block the undo names.
  """

  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.CalendarDirectory
  alias Tymeslot.CalendarGrid.EventDeletion
  alias Tymeslot.CalendarGrid.Moves
  alias Tymeslot.CalendarGrid.NewEvent
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Profiles
  alias Tymeslot.Validation.Constraints

  @typedoc """
  A block made. An event block keeps the start, end and title it was written
  with, so `unblock/2` can tell whether the event has been changed since.
  """
  @type blocked ::
          %{
            kind: :event,
            event: map(),
            start_at: DateTime.t(),
            end_at: DateTime.t(),
            title: String.t()
          }
          | %{kind: :time_off, period: TimeOff.period()}

  @type refusal ::
          :invalid_title
          | :invalid_range
          | :in_past
          | :too_long
          | :too_far
          | :not_cached
          | :changed
          | {:queued, term()}
          | :limit_reached
          | :not_found
          | :invalid
          | term()

  @doc """
  Blocks `start_at..end_at` for `user_id` under `title` (required, not
  blank). See the module doc for which kind of block it makes.
  """
  @spec block(pos_integer(), DateTime.t(), DateTime.t(), String.t()) ::
          {:ok, blocked()} | {:error, refusal()}
  def block(user_id, %DateTime{} = start_at, %DateTime{} = end_at, title)
      when is_integer(user_id) do
    with {:ok, title} <- clean_title(title),
         :ok <- check_span(start_at, end_at),
         {:ok, profile} <- Profiles.get_profile_by_user_id(user_id) do
      case target(CalendarGrid.list_active_integrations(user_id)) do
        {integration, entry} ->
          block_with_event(user_id, profile, integration, entry, start_at, end_at, title)

        nil ->
          block_with_time_off(profile, start_at, end_at, title)
      end
    end
  end

  @doc """
  Takes back a block `block/4` made: deletes the event (nobody was invited,
  so nobody is told) or the time off. `{:error, :not_found}` when the block
  is not the user's or is already gone, `{:error, :changed}` when the event
  has been moved or renamed since.
  """
  @spec unblock(pos_integer(), blocked()) :: :ok | {:error, term()}
  def unblock(
        user_id,
        %{kind: :event, event: %{calendar_integration_id: integration_id, uid: uid}} = blocked
      ) do
    with true <- CalendarIntegrationQueries.owned_by?(integration_id, user_id),
         {:ok, row} <- ProviderCalendarEventQueries.get_by_uid(integration_id, uid),
         :ok <- unchanged(row, blocked),
         {:ok, _deleted} <- EventDeletion.delete_event(user_id, row) do
      :ok
    else
      false -> {:error, :not_found}
      {:error, %{reason: reason, retry: :queued}} -> {:error, {:queued, reason}}
      {:error, %{reason: reason}} -> {:error, reason}
      {:error, _reason} = error -> error
    end
  end

  def unblock(user_id, %{kind: :time_off, period: %{id: period_id}}) do
    with {:ok, profile} <- Profiles.get_profile_by_user_id(user_id),
         {:ok, period} <- TimeOff.fetch(profile.id, period_id),
         {:ok, _deleted} <- TimeOff.delete(period) do
      :ok
    end
  end

  def unblock(_user_id, _result), do: {:error, :not_found}

  defp unchanged(row, %{start_at: start_at, end_at: end_at, title: title}) do
    if same_instant?(row.start_at, start_at) and same_instant?(row.end_at, end_at) and
         row.summary == title,
       do: :ok,
       else: {:error, :changed}
  end

  defp same_instant?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  defp same_instant?(_a, _b), do: false

  defp clean_title(title) when is_binary(title) do
    case title |> String.replace("\x00", "") |> String.trim() do
      "" -> {:error, :invalid_title}
      clean -> {:ok, clean}
    end
  end

  defp clean_title(_title), do: {:error, :invalid_title}

  @doc """
  Whether `start_at..end_at` can be blocked: it lasts more than nothing
  (`:invalid_range`), has not ended (`:in_past`) and is no longer than an
  event the calendar can draw, a week (`:too_long`). `block/4` asks it
  first; the calendar asks it before starting a block.
  """
  @spec check_span(DateTime.t(), DateTime.t()) ::
          :ok | {:error, :invalid_range | :in_past | :too_long}
  def check_span(%DateTime{} = start_at, %DateTime{} = end_at) do
    cond do
      DateTime.compare(end_at, start_at) != :gt -> {:error, :invalid_range}
      DateTime.compare(end_at, Clock.utc_now()) != :gt -> {:error, :in_past}
      DateTime.diff(end_at, start_at) > Moves.max_span_seconds() -> {:error, :too_long}
      true -> :ok
    end
  end

  # The first integration, in the order the calendar lists them, with a
  # writable calendar that blocks availability, on its default one of those.
  defp target(integrations) do
    Enum.find_value(integrations, fn integration ->
      blocking =
        integration
        |> CalendarDirectory.writable_calendars()
        |> Enum.filter(&Selection.blocking?/1)

      case Calendar.default_booking_calendar(
             blocking,
             Map.get(integration, :default_booking_calendar_id)
           ) do
        nil -> nil
        entry -> {integration, entry}
      end
    end)
  end

  defp block_with_event(user_id, profile, integration, entry, start_at, end_at, title) do
    payload = %{
      creating: %{
        title: title,
        integration_id: integration.id,
        calendar_id: entry.id,
        all_day: false,
        attendees: [],
        transparency: "opaque"
      },
      start_at: DateTime.truncate(start_at, :second),
      end_at: DateTime.truncate(end_at, :second),
      timezone: Profiles.timezone(profile)
    }

    case NewEvent.create(user_id, payload) do
      {:ok, %{event: %{} = event}} ->
        {:ok,
         %{
           kind: :event,
           event: event,
           start_at: event.start_at,
           end_at: event.end_at,
           title: event.summary
         }}

      {:ok, _no_cached_row} ->
        {:error, :not_cached}

      {:error, %{reason: reason, retry: :queued}} ->
        {:error, {:queued, reason}}

      {:error, %{reason: reason}} ->
        {:error, reason}
    end
  end

  # On the owner's clock, as time off is read. A block already under way
  # starts now, since time off refuses days that have gone; one ending at
  # midnight ends with its day (a nil end time).
  defp block_with_time_off(profile, start_at, end_at, title) do
    timezone = Profiles.timezone(profile)
    local_start = start_at |> latest(Clock.utc_now()) |> DateTime.shift_zone!(timezone)
    local_end = DateTime.shift_zone!(end_at, timezone)
    {ends_on, end_time} = period_end(local_end)

    attrs = %{
      starts_on: DateTime.to_date(local_start),
      start_time: local_start |> DateTime.to_time() |> Time.truncate(:second),
      ends_on: ends_on,
      end_time: end_time,
      label: String.slice(title, 0, Constraints.time_off_label_max_length())
    }

    case TimeOff.create(profile.id, attrs) do
      {:ok, period} -> {:ok, %{kind: :time_off, period: period}}
      {:error, :limit_reached} -> {:error, :limit_reached}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, time_off_refusal(changeset)}
    end
  end

  defp latest(a, b), do: Enum.max([a, b], DateTime)

  defp period_end(%DateTime{hour: 0, minute: 0, second: 0} = local_end),
    do: {local_end |> DateTime.to_date() |> Date.add(-1), nil}

  defp period_end(local_end),
    do: {DateTime.to_date(local_end), local_end |> DateTime.to_time() |> Time.truncate(:second)}

  # A horizon error carries its `count`; any other date error on either end
  # is a day that has gone.
  defp time_off_refusal(%Ecto.Changeset{errors: errors}) do
    cond do
      horizon?(Keyword.get(errors, :ends_on)) -> :too_far
      past?(Keyword.get(errors, :ends_on)) -> :in_past
      true -> :invalid
    end
  end

  defp horizon?({_message, opts}) when is_list(opts), do: Keyword.has_key?(opts, :count)
  defp horizon?(_error), do: false

  defp past?({"must not be in the past", _opts}), do: true
  defp past?(_error), do: false
end
