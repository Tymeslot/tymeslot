defmodule TymeslotWeb.Live.Scheduling.AvailabilityHelpers do
  @moduledoc """
  Availability calculation and fetch orchestration for the scheduling flow.

  Owns the slot lookup for a single date, the cached range query that
  powers the calendar grid, and the availability fetch task lifecycle.
  """

  alias Phoenix.Component
  alias Tymeslot.Availability.{Calculate, Schedules, TimeSlots}
  alias Tymeslot.Demo
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Meetings.BookingLimits.Checker
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.ContextUtils

  require Logger

  import Component, only: [assign: 3]

  @doc """
  Gets available slots for a specific date.
  """
  @spec get_available_slots(
          String.t(),
          String.t() | integer(),
          String.t(),
          integer(),
          map(),
          map() | nil
        ) :: {:ok, [map()]} | {:error, any()}
  def get_available_slots(
        date_string,
        duration,
        user_timezone,
        organizer_user_id,
        organizer_profile,
        context \\ nil
      ) do
    # Security: Ensure user_id matches the profile owner to prevent IDOR
    if organizer_profile && organizer_user_id != organizer_profile.user_id do
      {:error, :unauthorized}
    else
      with {:ok, date} <- Date.from_iso8601(date_string),
           {:ok, owner_timezone} <- get_owner_timezone(organizer_profile) do
        # Check if this is a demo user
        if Demo.demo_profile?(organizer_profile) ||
             ContextUtils.get_from_context(context, :demo_mode) do
          # Use demo provider for availability generation
          Demo.get_available_slots(
            date_string,
            duration,
            user_timezone,
            organizer_user_id,
            organizer_profile,
            context
          )
        else
          # Regular flow for real users
          with {:ok, events} <-
                 CalendarEvents.get_calendar_events_from_context(
                   date,
                   organizer_user_id,
                   context
                 ),
               duration_minutes <- parse_duration_minutes(duration) do
            schedule =
              Schedules.resolve_for(
                ContextUtils.get_from_context(context, :meeting_type),
                organizer_profile
              )

            config = %{
              schedule_id: schedule && schedule.id,
              max_advance_booking_days: Schedules.policy(schedule, :advance_booking_days),
              min_advance_hours: Schedules.policy(schedule, :min_advance_hours),
              buffer_minutes: Schedules.policy(schedule, :buffer_minutes),
              limit_checker:
                build_limit_checker(organizer_user_id, organizer_profile, context, date, date)
            }

            Calculate.available_slots(
              date,
              duration_minutes,
              user_timezone,
              owner_timezone,
              events,
              config
            )
          end
        end
      end
    end
  end

  @doc """
  Gets availability map for a date range showing which days have actual free slots.

  This fetches calendar events and calculates real availability
  including conflicts, used to grey out fully booked days.

  ## Parameters
    - user_id: The organizer's user ID
    - start_date: First date in the range (inclusive)
    - end_date: Last date in the range (inclusive)
    - user_timezone: Timezone of the user viewing
    - organizer_profile: Profile with booking settings
    - context: Optional context map (replacing socket)
    - duration_minutes: Optional meeting duration in minutes

  ## Returns
    - `{:ok, map}` where map keys are date strings ("2026-01-15") and values are booleans
    - `{:error, reason}` if calendar fetch fails
  """
  @spec get_range_availability(
          integer(),
          Date.t(),
          Date.t(),
          String.t(),
          map(),
          map() | nil,
          integer() | nil
        ) :: {:ok, map()} | {:error, any()}
  def get_range_availability(
        user_id,
        start_date,
        end_date,
        user_timezone,
        organizer_profile,
        context \\ nil,
        duration_minutes \\ nil
      ) do
    # Security: Ensure user_id matches the profile owner to prevent IDOR
    cond do
      organizer_profile && user_id != organizer_profile.user_id ->
        {:error, :unauthorized}

      Demo.demo_profile?(organizer_profile) || ContextUtils.get_from_context(context, :demo_mode) ->
        # Delegate to demo provider
        Demo.get_range_availability(
          user_id,
          start_date,
          end_date,
          user_timezone,
          organizer_profile,
          context,
          duration_minutes
        )

      true ->
        with {:ok, owner_timezone} <- get_owner_timezone(organizer_profile) do
          meeting_type = ContextUtils.get_from_context(context, :meeting_type)

          cache_key =
            AvailabilityCache.availability_range_key(
              user_id,
              start_date,
              end_date,
              user_timezone,
              duration_minutes,
              meeting_type && meeting_type.id
            )

          AvailabilityCache.get_or_compute_events(cache_key, fn ->
            with {:ok, events} <- booking_window_events(user_id, start_date, context) do
              schedule = Schedules.resolve_for(meeting_type, organizer_profile)

              config = %{
                schedule_id: schedule && schedule.id,
                max_advance_booking_days: Schedules.policy(schedule, :advance_booking_days),
                min_advance_hours: Schedules.policy(schedule, :min_advance_hours),
                buffer_minutes: Schedules.policy(schedule, :buffer_minutes),
                duration_minutes: duration_minutes || 30,
                limit_checker:
                  build_limit_checker(user_id, organizer_profile, context, start_date, end_date)
              }

              Calculate.range_availability(
                start_date,
                end_date,
                owner_timezone,
                user_timezone,
                events,
                config
              )
            end
          end)
        end
    end
  end

  @doc """
  Starts the month availability fetch and marks the socket as loading.

  The result always comes back as a `{ref, result}` message finalised by
  `TymeslotWeb.Themes.Shared.InfoHandlers`, in every environment. There
  is no second finaliser, so no test can pin behaviour production never
  has; see `start_availability_task/2` for the one thing that does vary.
  """
  @spec perform_availability_fetch(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def perform_availability_fetch(socket) do
    context = %{
      demo_mode: Demo.demo_mode?(socket),
      organizer_profile: socket.assigns.organizer_profile,
      meeting_type: socket.assigns[:meeting_type],
      debug_calendar_module: socket.private[:debug_calendar_module]
    }

    start_time = System.monotonic_time()

    socket =
      socket
      |> assign(:month_availability_map, :loading)
      |> assign(:availability_status, :loading)
      |> assign(:availability_fetch_start_time, start_time)

    start_availability_task(socket, context)
  end

  @doc """
  Safely initiates an asynchronous month availability fetch if all requirements are met.
  Cancels any existing fetch task before starting a new one.
  """
  @spec fetch_month_availability_async(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def fetch_month_availability_async(socket) do
    if can_fetch_availability?(socket) do
      socket
      |> maybe_cancel_existing_task()
      |> perform_availability_fetch()
    else
      socket
    end
  end

  @doc """
  Checks if all conditions for fetching availability are met.
  """
  @spec can_fetch_availability?(Phoenix.LiveView.Socket.t()) :: boolean()
  def can_fetch_availability?(socket) do
    socket.assigns[:organizer_user_id] &&
      socket.assigns[:organizer_profile] &&
      socket.assigns[:current_year] &&
      socket.assigns[:current_month]
  end

  @doc """
  Cancels any existing availability fetch task.
  """
  @spec maybe_cancel_existing_task(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def maybe_cancel_existing_task(socket) do
    socket =
      if old_task = socket.assigns[:availability_task] do
        duration =
          case socket.assigns[:availability_fetch_start_time] do
            nil -> "unknown"
            start -> "#{System.monotonic_time() - start}ns"
          end

        Logger.debug("Cancelling previous availability fetch task due to user navigation",
          duration: duration,
          user_id: Map.get(socket.assigns, :organizer_user_id),
          month: Map.get(socket.assigns, :current_month),
          year: Map.get(socket.assigns, :current_year)
        )

        Task.shutdown(old_task, :brutal_kill)
        assign(socket, :availability_task, nil)
      else
        socket
      end

    # Always clear the ref so a result already in flight for the previous
    # window is ignored when it arrives.
    assign(socket, :availability_task_ref, nil)
  end

  # The fetch runs in a linked task, or inline under the deterministic
  # harness, but *both modes deliver the result identically*: a
  # `{ref, {:ok, map}}` / `{ref, {:error, reason}}` message that
  # `TymeslotWeb.Themes.Shared.InfoHandlers` finalises after `mount` and
  # `handle_params/3` have run. The ref match, the loaded/error
  # transitions, the landing on the first bookable day and its refetch
  # hop are therefore one code path with one ordering, whichever mode is
  # selected — the divergence the two-branch fetch used to introduce was
  # not the concurrency, it was the second finaliser and the second
  # ordering that came with it.
  #
  # `:async_availability_fetch` picks the mode. It defaults to `true`;
  # `config/test.exs` sets it `false` so the result is owned by the test
  # process: a task still in flight when a test ends is killed mid-query
  # and takes the checked-out sandbox connection down with it, failing
  # every test that follows. It is a named behavioural flag rather than
  # an `:environment` comparison so a test can opt *back into* the task
  # path (`AvailabilityAsyncFetchTest` does) instead of the whole suite
  # being locked out of the branch that ships.
  #
  # `Task.async/1` links, so the task's lifetime is exactly the
  # LiveView's: a booker who closes the tab cannot leave a calendar fetch
  # running behind them. The cost of the link is that a fetch which
  # *raises* takes the page down with it rather than arriving as a
  # `:DOWN` — which is why `InfoHandlers` has no `:DOWN` handler.
  defp start_availability_task(socket, context) do
    # Extract values needed for closure to avoid capturing socket
    organizer_user_id = socket.assigns.organizer_user_id
    current_year = socket.assigns.current_year
    current_month = socket.assigns.current_month
    user_timezone = socket.assigns.user_timezone
    organizer_profile = socket.assigns.organizer_profile

    duration_minutes = duration_minutes(socket)
    {start_date, end_date} = Calculate.display_range(current_year, current_month)

    fetch = fn ->
      get_range_availability(
        organizer_user_id,
        start_date,
        end_date,
        user_timezone,
        organizer_profile,
        context,
        duration_minutes
      )
    end

    if async_fetch?() do
      task = Task.async(fetch)

      socket
      |> assign(:availability_task, task)
      |> assign(:availability_task_ref, task.ref)
    else
      # Same message, same mailbox, same arrival point — just computed
      # by this process instead of a task it would have to wait for.
      ref = make_ref()
      send(self(), {ref, fetch.()})

      socket
      |> assign(:availability_task, nil)
      |> assign(:availability_task_ref, ref)
    end
  end

  defp async_fetch?, do: Application.get_env(:tymeslot, :async_availability_fetch, true)

  # The provider fetch behind this is window-shaped, not month-shaped:
  # `Events.get_calendar_events/3` ignores the date it is given and always asks
  # for `today .. today + advance_booking_days`. Folding it under a key built
  # from the 42-day *display* range therefore stores the same event list once
  # per rendered month and guarantees a miss for anything that moves the
  # calendar — worst of all the next-available forward search, which re-enters
  # this function once per hop and would otherwise buy an identical round trip
  # to the host's calendar each time, on exactly the fully booked hosts the
  # search exists to help.
  #
  # So the events get their own entry, keyed on the user alone because that is
  # the fetch's entire input. The folded map keeps its display-range key: the
  # fold is what actually differs between hops.
  #
  # Errors stay uncached, for the reason `get_or_compute_events/2` exists at
  # all — a timed-out calendar must be retried on the next request, not pinned
  # empty for the TTL. `AvailabilityCache.invalidate_for_user/1` drops this
  # entry with the folded maps, so a calendar sync cannot leave the two
  # disagreeing about how fresh they are.
  defp booking_window_events(user_id, start_date, context) do
    AvailabilityCache.get_or_compute_events(
      AvailabilityCache.booking_window_events_key(user_id),
      fn -> CalendarEvents.get_calendar_events_from_context(start_date, user_id, context) end
    )
  end

  defp parse_duration_minutes(duration) when is_integer(duration) and duration > 0 do
    min(duration, 1440)
  end

  defp parse_duration_minutes(duration) when is_binary(duration) do
    mins = TimeSlots.parse_duration(duration)
    min(mins, 1440)
  end

  defp parse_duration_minutes(_other), do: 30

  defp get_owner_timezone(organizer_profile) do
    {:ok, organizer_profile.timezone || Profiles.get_default_timezone()}
  end

  # Returns nil when the host has no booking limits configured, keeping the
  # common path free of extra queries.
  defp build_limit_checker(organizer_user_id, organizer_profile, context, start_date, end_date) do
    Checker.build_slot_checker(
      organizer_user_id,
      organizer_profile,
      ContextUtils.get_from_context(context, :meeting_type),
      start_date,
      end_date
    )
  end

  @doc """
  The meeting length the flow is operating on, in minutes.

  The resolved meeting type is authoritative; only when there is none does the
  slug fall back to a parse, and that parse is bounded — the slug is visitor
  input, so an unbounded one would let `/:username/99999/book` hold a
  multi-day slot. The single resolver exists so the display path and the
  submit path cannot disagree about the bound.
  """
  @spec duration_minutes(Phoenix.LiveView.Socket.t()) :: pos_integer()
  def duration_minutes(socket) do
    case socket.assigns[:meeting_type] do
      %{duration_minutes: mins} when is_integer(mins) ->
        mins

      _unresolved ->
        parse_duration_minutes(socket.assigns[:duration] || socket.assigns[:selected_duration])
    end
  end
end
