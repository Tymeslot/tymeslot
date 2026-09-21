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
  failure is logged and waved through.

  ## The meeting being moved is not a conflict with itself

  A reschedule's fresh fetch returns the meeting's own provider event, because
  Tymeslot wrote it to the host's calendar when the booking was made. Left in,
  it would refuse every move onto a time overlapping (or, through the buffer,
  merely adjacent to) the slot the meeting already occupies, so a booking
  could not be nudged by fifteen minutes. Pass the meeting as `:exclude` and
  its mirror is dropped before the conflict check runs.
  `Tymeslot.Meetings.CalendarEventLink` owns the rule for which event that is,
  because the identifier the two sides share differs by provider family.
  """

  require Logger

  alias Tymeslot.Bookings.Validation
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Meetings

  # Availability was already checked when the slots were displayed, so a slow
  # calendar must not hold the submit open: past this, the booking proceeds on
  # what the display path knew.
  @fetch_timeout_ms 5_000

  # Distinct from a transport error: the fetch DID reach the calendar layer,
  # which reported that it could not read every selected calendar. The busy set
  # is therefore incomplete, and proceeding would skip the conflict check
  # entirely, strictly worse than checking against a partial set, because a
  # clash sitting in a calendar that did respond would be missed too.
  @unverifiable_reasons [:some_calendars_unavailable, :all_calendars_unavailable]

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
          | term()

  @typedoc "What the shared refusal policy decided."
  @type enforce_reason :: :organizer_required | :slot_unavailable | :availability_unverifiable

  @doc """
  Reads the organiser's calendars afresh and reports whether `slot` is free.

  Returns `:ok`, `{:error, :slot_unavailable}` for a clash, and the calendar
  layer's own reason for everything else, so a caller that wants to fail fast
  on a clash while tolerating an unreachable provider (the pre-check in
  `Create.execute_with_video_room/3`) can tell them apart. Most callers want
  `enforce/3` instead.

  Options:

    * `:exclude` - a meeting whose own provider event must not count as a
      conflict. See the module doc.
  """
  @spec probe(slot(), map(), keyword()) :: :ok | {:error, probe_reason()}
  def probe(slot, config, opts \\ [])

  def probe(%{organizer_user_id: organizer_user_id} = slot, config, opts)
      when is_integer(organizer_user_id) do
    %{start_datetime: start_datetime, end_datetime: end_datetime} = slot
    {start_date, end_date} = fetch_range(slot, Map.get(config, :buffer_minutes, 15))

    fetch =
      Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
        CalendarEvents.get_events_for_range_fresh(organizer_user_id, start_date, end_date)
      end)

    case Task.yield(fetch, @fetch_timeout_ms) || Task.shutdown(fetch) do
      {:ok, {:ok, events}} ->
        Validation.validate_no_conflicts(
          start_datetime,
          end_datetime,
          Meetings.reject_calendar_event_mirrors(events, Keyword.get(opts, :exclude)),
          config
        )

      {:ok, {:error, reason}} ->
        {:error, reason}

      nil ->
        Logger.warning("Calendar availability check timed out",
          organizer_user_id: organizer_user_id,
          timeout_ms: @fetch_timeout_ms
        )

        {:error, :timeout}
    end
  end

  def probe(_slot, _config, _opts), do: {:error, :organizer_required}

  @doc """
  `probe/3` with the refusal policy both submits share applied.

  A clash refuses with `:slot_unavailable`, and a busy set we could not read in
  full refuses with `:availability_unverifiable`: the booker gets the same
  "pick another slot" outcome either way, and the distinction survives in the
  logs rather than in the copy. A transport or timeout failure is logged and
  returns `:ok`: the slot was already validated against the display path, and
  an unreachable provider must not take the booking page down with it.

  Takes the same options as `probe/3`.
  """
  @spec enforce(slot(), map(), keyword()) :: :ok | {:error, enforce_reason()}
  def enforce(slot, config, opts \\ []) do
    case probe(slot, config, opts) do
      :ok ->
        :ok

      {:error, reason} when reason in [:slot_unavailable, :organizer_required] ->
        {:error, reason}

      {:error, reason} when reason in @unverifiable_reasons ->
        Logger.warning("Calendar availability could not be verified, refusing booking",
          reason: inspect(reason),
          organizer_user_id: Map.get(slot, :organizer_user_id)
        )

        {:error, :availability_unverifiable}

      {:error, reason} ->
        Logger.warning("Calendar availability check failed, proceeding with booking",
          reason: inspect(reason),
          organizer_user_id: Map.get(slot, :organizer_user_id)
        )

        :ok
    end
  end

  # The fetch asks providers for whole UTC days, so the range has to be derived
  # from the slot's own UTC instants rather than from the visitor's local date:
  # 10:00 in Auckland is the previous day in UTC, and a range built from the
  # local date would not contain the slot at all. The buffer is folded in
  # because a conflict is anything within `buffer_minutes` of the slot, which
  # can sit on the neighbouring day.
  defp fetch_range(%{start_datetime: start_datetime, end_datetime: end_datetime}, buffer_minutes) do
    {utc_date(start_datetime, -buffer_minutes), utc_date(end_datetime, buffer_minutes)}
  end

  defp utc_date(datetime, offset_minutes) do
    datetime
    |> DateTime.add(offset_minutes, :minute)
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_date()
  end
end
