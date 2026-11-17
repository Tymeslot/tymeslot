defmodule Tymeslot.Bookings.CalendarCheck do
  @moduledoc """
  The submit-time re-read of the organiser's connected calendars.

  A booking page draws its grid from cached, window-fetched events, so the host
  can block a time in Google, Outlook or CalDAV between the visitor seeing a
  slot and pressing the button. Both submits therefore re-read the calendars
  here, bypassing every cache, before anything is written:
  `Tymeslot.Bookings.Create` for a new booking, `Tymeslot.Bookings.Reschedule`
  for a move. Sharing one check is what stops the two from disagreeing about
  what "free" means; the reschedule path had no such check at all until it
  started calling this.

  `probe/3` reports what the calendars said and leaves the decision to the
  caller. `enforce/3` adds the refusal policy both submits share: a genuine
  clash and an incompletely readable busy set are refused, while a transport
  failure is logged and waved through. `probe_many/3` and `enforce_many/3`
  answer the same for the sessions of a series from a single fetch.

  ## The meeting being moved is not a conflict with itself

  A reschedule's fresh fetch returns the meeting's own provider event, because
  Tymeslot wrote it to the host's calendar when the booking was made. Left in,
  it would refuse every move onto a time overlapping (or, through a buffer,
  merely adjacent to) the slot the meeting already occupies, so a booking
  could not be nudged by fifteen minutes. Pass the meeting as `:exclude` and
  its mirror is dropped before the conflict check runs.
  `Tymeslot.Meetings.CalendarEventLink` owns the rule for which event that is,
  because the identifier the two sides share differs by provider family.

  ## "Treat as" choices

  The fresh events go through the same bookability rule as the booking page
  (`Tymeslot.Availability.Bookability.apply_to_busy/3`), so an all-day event
  the organiser treats as busy refuses here exactly when the page leaves it
  out, and one they treat as free is not a clash.
  """

  require Logger

  alias Tymeslot.Availability.Bookability
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Bookings.Validation
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Meetings.ExternalCalendar

  # Availability was already checked when the slots were displayed, so a slow
  # calendar must not hold the submit open: past this, the booking proceeds on
  # what the display path knew.
  @fetch_timeout_ms 5_000

  # A series reads up to a year of calendar in one fetch, which a provider
  # can take longer to page through than a single slot's few days.
  @range_threshold_days 31
  @range_fetch_timeout_ms 10_000

  # Distinct from a transport error: the fetch DID reach the calendar layer,
  # which reported that it could not read every selected calendar. The busy set
  # is therefore incomplete, and proceeding would skip the conflict check
  # entirely, strictly worse than checking against a partial set, because a
  # clash sitting in a calendar that did respond would be missed too.
  #
  # A fetch that crashed (a provider adapter raising past its own handling)
  # joins them: nothing was read, and nothing says the slot is free, so the
  # booking is refused rather than confirmed on no evidence at all.
  @unverifiable_reasons [:some_calendars_unavailable, :all_calendars_unavailable, :fetch_crashed]

  @typedoc """
  The slot to check. Any map carrying the two instants and the organiser
  qualifies, so `Create` passes its whole `booking_data` unchanged.
  """
  @type slot :: %{
          required(:start_datetime) => DateTime.t(),
          required(:end_datetime) => DateTime.t(),
          optional(:organizer_user_id) => pos_integer() | nil,
          optional(atom()) => term()
        }

  @typedoc "What the calendars said, unpoliced."
  @type probe_reason ::
          :organizer_required
          | :slot_unavailable
          | :some_calendars_unavailable
          | :all_calendars_unavailable
          | :timeout
          | :fetch_crashed
          | term()

  @typedoc "What the shared refusal policy decided."
  @type enforce_reason :: :organizer_required | :slot_unavailable | :availability_unverifiable

  @doc """
  Reads the organiser's calendars afresh and reports whether `slot` is free.

  Returns `:ok`, `{:error, :slot_unavailable}` for a clash,
  `{:error, :fetch_crashed}` when the fetch itself crashed, and the calendar
  layer's own reason for everything else, so a caller can tell a clash from
  an unreachable provider. Most callers want `enforce/3` instead.

  The fetch runs in an unlinked task, so a provider adapter that raises is
  reported here as `:fetch_crashed` instead of taking the caller (the
  booker's LiveView) down with it.

  Options:

    * `:exclude` - a meeting, or a list of meetings, whose own provider
      events must not count as a conflict: the meeting being moved, the
      group meeting a seat joins, or the one a seat move vacates.
      See the module doc.
  """
  @spec probe(slot(), map(), keyword()) :: :ok | {:error, probe_reason()}
  def probe(slot, config, opts \\ [])

  def probe(%{organizer_user_id: organizer_user_id} = slot, config, opts)
      when is_integer(organizer_user_id) do
    range = fetch_range(slot, Calculate.config_buffers(config))

    with {:ok, blocking} <- fetch_blocking(organizer_user_id, range, @fetch_timeout_ms, opts) do
      check_slot(slot, blocking, config)
    end
  end

  def probe(_slot, _config, _opts), do: {:error, :organizer_required}

  @doc """
  `probe/3` with the refusal policy both submits share applied.

  A clash refuses with `:slot_unavailable`, and a busy set we could not read in
  full refuses with `:availability_unverifiable`, which the booker is told to
  try again later, since every other slot would be refused the same way. A fetch that crashed counts as unreadable. A
  transport or timeout failure is logged and returns `:ok`: the slot was
  already validated against the display path, and an unreachable provider
  must not take the booking page down with it.

  Takes the same options as `probe/3`.
  """
  @spec enforce(slot(), map(), keyword()) :: :ok | {:error, enforce_reason()}
  def enforce(slot, config, opts \\ []) do
    case probe(slot, config, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        with :proceed <- police(reason, Map.get(slot, :organizer_user_id), false), do: :ok
    end
  end

  @doc """
  `probe/3` for many slots of one organiser at once, as a series asks: one
  fresh fetch over `[earliest start - before-buffer, latest end + after-buffer]`,
  then each slot weighed exactly as `probe/3` weighs one.

  Returns `{:ok, %{busy: starts}}`, the set of slot starts that clash, or the
  same errors as `probe/3`. A range wider than #{@range_threshold_days} days
  waits #{@range_fetch_timeout_ms} ms for the providers rather than
  #{@fetch_timeout_ms}. Every slot must belong to the same organiser.

  Takes the same options as `probe/3`.
  """
  @spec probe_many([slot()], map(), keyword()) ::
          {:ok, %{busy: MapSet.t(DateTime.t())}} | {:error, probe_reason()}
  def probe_many(slots, config, opts \\ [])

  def probe_many([], _config, _opts), do: {:ok, %{busy: MapSet.new()}}

  def probe_many([%{organizer_user_id: organizer_user_id} | _rest] = slots, config, opts)
      when is_integer(organizer_user_id) do
    buffers = Calculate.config_buffers(config)

    {start_date, end_date} =
      slots
      |> Enum.map(&fetch_range(&1, buffers))
      |> Enum.unzip()
      |> then(fn {starts, ends} -> {Enum.min(starts, Date), Enum.max(ends, Date)} end)

    timeout =
      if Date.diff(end_date, start_date) > @range_threshold_days,
        do: @range_fetch_timeout_ms,
        else: @fetch_timeout_ms

    with {:ok, blocking} <-
           fetch_blocking(organizer_user_id, {start_date, end_date}, timeout, opts) do
      busy =
        for slot <- slots, check_slot(slot, blocking, config) != :ok, into: MapSet.new() do
          slot.start_datetime
        end

      {:ok, %{busy: busy}}
    end
  end

  def probe_many(_slots, _config, _opts), do: {:error, :organizer_required}

  @doc """
  `probe_many/3` with `enforce/3`'s refusal policy: an unreadable busy set
  refuses the whole set with `:availability_unverifiable`, and a transport
  failure is logged and reads as nothing busy.

  Takes the same options as `probe/3`, plus `strict_calendar: true`, which
  refuses a transport failure or a timeout with `:availability_unverifiable`
  too. Booking a series writes many sessions at once, often months of them,
  so it must not book them over clashes nobody could read; a single booking
  and a preview keep the lenient default.
  """
  @spec enforce_many([slot()], map(), keyword()) ::
          {:ok, %{busy: MapSet.t(DateTime.t())}}
          | {:error, :organizer_required | :availability_unverifiable}
  def enforce_many(slots, config, opts \\ []) do
    organizer_user_id =
      case slots do
        [first | _rest] -> Map.get(first, :organizer_user_id)
        [] -> nil
      end

    case probe_many(slots, config, opts) do
      {:ok, _busy} = ok ->
        ok

      {:error, reason} ->
        strict? = Keyword.get(opts, :strict_calendar, false)

        with :proceed <- police(reason, organizer_user_id, strict?),
             do: {:ok, %{busy: MapSet.new()}}
    end
  end

  # The refusal policy `enforce/3` and `enforce_many/3` share: the error a
  # probe failure refuses with, or `:proceed` for a transport failure, which
  # each caller answers with its own nothing-busy result. A strict caller
  # refuses a transport failure too.
  defp police(reason, _organizer_user_id, _strict?)
       when reason in [:organizer_required, :slot_unavailable],
       do: {:error, reason}

  defp police(reason, organizer_user_id, _strict?) when reason in @unverifiable_reasons do
    Logger.warning("Calendar availability could not be verified, refusing booking",
      reason: LogFormat.reason(reason),
      organizer_user_id: organizer_user_id
    )

    {:error, :availability_unverifiable}
  end

  defp police(reason, organizer_user_id, true) do
    Logger.warning("Calendar availability check failed, refusing booking",
      reason: LogFormat.reason(reason),
      organizer_user_id: organizer_user_id
    )

    {:error, :availability_unverifiable}
  end

  defp police(reason, organizer_user_id, false) do
    Logger.warning("Calendar availability check failed, proceeding with booking",
      reason: LogFormat.reason(reason),
      organizer_user_id: organizer_user_id
    )

    :proceed
  end

  # One fresh read of the organiser's calendars over `{start_date, end_date}`,
  # less the mirrors of the meetings `opts[:exclude]` names. The fetch runs in
  # an unlinked task, so a provider adapter that raises is reported as
  # `:fetch_crashed` instead of taking the caller down with it.
  defp fetch_blocking(organizer_user_id, {start_date, end_date}, timeout_ms, opts) do
    fetch =
      Tasks.async_nolink(Tymeslot.TaskSupervisor, fn ->
        CalendarEvents.get_events_for_range_fresh(organizer_user_id, start_date, end_date)
      end)

    case Task.yield(fetch, timeout_ms) || Task.shutdown(fetch) do
      {:ok, {:ok, events}} ->
        {:ok,
         events
         |> Bookability.apply_to_busy(organizer_user_id, {start_date, end_date})
         |> ExternalCalendar.reject_calendar_event_mirrors(Keyword.get(opts, :exclude))}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:exit, reason} ->
        Logger.error("Calendar availability check crashed",
          organizer_user_id: organizer_user_id,
          reason: LogFormat.reason(reason)
        )

        {:error, :fetch_crashed}

      nil ->
        Logger.warning("Calendar availability check timed out",
          organizer_user_id: organizer_user_id,
          timeout_ms: timeout_ms
        )

        {:error, :timeout}
    end
  end

  # Whether one slot clashes with the events read, by the overlap and buffer
  # rules of the booking path: the one rule `probe/3` and `probe_many/3` share.
  defp check_slot(
         %{start_datetime: start_datetime, end_datetime: end_datetime},
         blocking,
         config
       ),
       do: Validation.validate_no_conflicts(start_datetime, end_datetime, blocking, config)

  # The fetch asks providers for whole UTC days, so the range has to be derived
  # from the slot's own UTC instants rather than from the visitor's local date:
  # 10:00 in Auckland is the previous day in UTC, and a range built from the
  # local date would not contain the slot at all. The buffers are folded in
  # because a conflict is anything within the before-buffer ahead of the slot
  # or the after-buffer behind it, and either can reach a neighbouring day.
  #
  # The range is then padded by a day each side, because an all-day event
  # blocks the host's local day (`Availability.Events.to_interval/2`), which
  # can sit in the UTC day before or after the slot's: for a host in Honolulu
  # a 15:00 slot is the next UTC day, and a provider asked only about that day
  # would not return the host's all-day event at all.
  defp fetch_range(
         %{start_datetime: start_datetime, end_datetime: end_datetime},
         {buffer_before, buffer_after}
       ) do
    {
      start_datetime |> utc_date(-buffer_before) |> Date.add(-1),
      end_datetime |> utc_date(buffer_after) |> Date.add(1)
    }
  end

  defp utc_date(datetime, offset_minutes) do
    datetime
    |> DateTime.add(offset_minutes, :minute)
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_date()
  end
end
