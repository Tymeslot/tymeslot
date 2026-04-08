defmodule TymeslotWeb.Live.Scheduling.Helpers do
  @moduledoc """
  Shared helper functions for the scheduling flow.
  Contains common logic used across multiple scheduling components.
  """

  alias Phoenix.Component
  alias Tymeslot.Availability.{BusinessHours, Calculate, TimeSlots}
  alias Tymeslot.Demo
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Profiles
  alias Tymeslot.Security.InputProcessor
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.{ContextUtils, DateTimeUtils}
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Scheduling.BookingConfig
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  require Logger

  import Component, only: [assign: 3]

  @doc """
  Handles username resolution and organizer setup.
  """
  @spec handle_username_resolution(Phoenix.LiveView.Socket.t(), String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def handle_username_resolution(socket, nil) do
    socket
    |> store_client_ip()
    |> assign(:username_context, nil)
  end

  def handle_username_resolution(socket, username) do
    # Store client IP during username resolution to ensure it's available later
    socket = store_client_ip(socket)

    case Demo.resolve_organizer_context(username) do
      {:error, :profile_not_found} ->
        # During mount, we can't use put_flash/redirect - let the mount handle this
        socket
        |> assign(:username_context, nil)
        |> assign(:organizer_profile, nil)
        |> assign(:organizer_user_id, nil)
        |> assign(:meeting_types, [])
        |> assign(:page_title, "User Not Found")

      {:ok, context} ->
        socket
        |> assign(:username_context, context.username)
        |> assign(:organizer_profile, context.profile)
        |> assign(:organizer_user_id, context.user_id)
        |> assign(:meeting_types, context.meeting_types)
        |> assign(:page_title, context.page_title)
    end
  end

  # Form state helpers
  @spec setup_form_state(Phoenix.LiveView.Socket.t(), map(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def setup_form_state(socket, form_data \\ %{}, opts \\ []) do
    as = Keyword.get(opts, :as)

    socket
    |> assign(:form, Component.to_form(form_data, as: as))
    |> assign(:touched_fields, MapSet.new())
    |> assign(:validation_errors, %{})
    |> assign(:saving, false)
  end

  @spec assign_form_errors(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def assign_form_errors(socket, error_map) when is_map(error_map) do
    assign(socket, :validation_errors, error_map)
  end

  @doc """
  Returns a CSS class if the field has errors.
  """
  @spec field_error_class(Phoenix.HTML.Form.t(), atom()) :: String.t()
  def field_error_class(form, field) do
    if Enum.any?(get_field_errors(form, field)), do: "error", else: ""
  end

  @doc """
  Gets error messages for a specific field from the form.
  """
  @spec get_field_errors(Phoenix.HTML.Form.t(), atom()) :: [String.t()]
  def get_field_errors(form, field) do
    case form[field] do
      %{errors: errors} when is_list(errors) ->
        Enum.map(errors, fn {msg, _opts} -> msg end)

      _other ->
        []
    end
  end

  @doc """
  Marks a form field as touched.
  """
  @spec mark_field_touched(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def mark_field_touched(socket, field_name) do
    assign(socket, :touched_fields, MapSet.put(socket.assigns.touched_fields, field_name))
  end

  @doc """
  Gets client IP address for rate limiting.
  Delegates to the unified ClientIP module.
  """
  @spec get_client_ip(Phoenix.LiveView.Socket.t()) :: String.t()
  def get_client_ip(socket) do
    ClientIP.get(socket)
  end

  @doc """
  Stores client IP in socket assigns during mount.
  Should be called during mount to capture IP for later use.
  """
  @spec store_client_ip(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def store_client_ip(socket) do
    # Try mount-specific extraction first if not already in assigns
    ip =
      case socket.assigns[:client_ip] do
        ip when is_binary(ip) ->
          ip

        _other ->
          # get_from_mount/1 should only be called during mount.
          # We wrap it in try-rescue to prevent crashes if called during events.
          try do
            ClientIP.get_from_mount(socket)
          rescue
            _error -> "unknown"
          end
      end

    assign(socket, :client_ip, ip)
  end

  @doc """
  Validates if form is complete and valid.
  """
  @spec form_valid?(Phoenix.HTML.Form.t()) :: boolean()
  def form_valid?(%{source: source}) when is_map(source) do
    case InputProcessor.validate_form(source, BookingConfig.booking_field_spec()) do
      {:ok, _result} -> true
      {:error, _reason} -> false
    end
  end

  def form_valid?(_form), do: false

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
        if demo_user?(organizer_profile) || ContextUtils.get_from_context(context, :demo_mode) do
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
            config = %{
              profile_id: organizer_profile.id,
              max_advance_booking_days: organizer_profile.advance_booking_days,
              min_advance_hours: organizer_profile.min_advance_hours,
              buffer_minutes: organizer_profile.buffer_minutes
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

      demo_user?(organizer_profile) || ContextUtils.get_from_context(context, :demo_mode) ->
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
          cache_key =
            AvailabilityCache.availability_range_key(
              user_id,
              start_date,
              end_date,
              user_timezone,
              duration_minutes
            )

          AvailabilityCache.get_or_compute(cache_key, fn ->
            with {:ok, events} <-
                   CalendarEvents.get_calendar_events_from_context(
                     start_date,
                     user_id,
                     context
                   ) do
              config = %{
                profile_id: organizer_profile.id,
                max_advance_booking_days: organizer_profile.advance_booking_days,
                min_advance_hours: organizer_profile.min_advance_hours,
                buffer_minutes: organizer_profile.buffer_minutes,
                duration_minutes: duration_minutes
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
  Orchestrates fetching availability for a month, either synchronously (in tests) or asynchronously.
  Updates the socket with loading states and task references.
  """
  @spec perform_availability_fetch(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def perform_availability_fetch(socket) do
    context = %{
      demo_mode: Demo.demo_mode?(socket),
      organizer_profile: socket.assigns.organizer_profile,
      debug_calendar_module: socket.private[:debug_calendar_module]
    }

    start_time = System.monotonic_time()

    socket =
      socket
      |> assign(:month_availability_map, :loading)
      |> assign(:availability_status, :loading)
      |> assign(:availability_fetch_start_time, start_time)

    if Application.get_env(:tymeslot, :environment) == :test do
      perform_sync_availability_fetch(socket, context)
    else
      perform_async_availability_fetch(socket, context)
    end
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

    # Always clear the ref to ensure any pending messages (sync or async) are ignored
    assign(socket, :availability_task_ref, nil)
  end

  @doc """
  Performs a truly synchronous availability fetch for test environments.

  Unlike the async version, this directly updates the socket with availability data
  instead of using message passing, making tests deterministic and faster.
  """
  @spec perform_sync_availability_fetch(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def perform_sync_availability_fetch(socket, context) do
    duration_minutes = get_duration_minutes(socket)

    {start_date, end_date} =
      display_range(socket.assigns.current_year, socket.assigns.current_month)

    case get_range_availability(
           socket.assigns.organizer_user_id,
           start_date,
           end_date,
           socket.assigns.user_timezone,
           socket.assigns.organizer_profile,
           context,
           duration_minutes
         ) do
      {:ok, availability_map} ->
        socket
        |> assign(:month_availability_map, availability_map)
        |> assign(:availability_status, :loaded)
        |> assign(:availability_task, nil)
        |> assign(:availability_task_ref, nil)

      {:error, reason} ->
        Logger.warning("Month availability fetch failed in sync mode", reason: inspect(reason))

        socket
        |> assign(:month_availability_map, nil)
        |> assign(:availability_status, :error)
        |> assign(:availability_task, nil)
        |> assign(:availability_task_ref, nil)
    end
  end

  @doc """
  Performs an asynchronous availability fetch using Task.async.
  """
  @spec perform_async_availability_fetch(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def perform_async_availability_fetch(socket, context) do
    # Extract values needed for closure to avoid capturing socket
    organizer_user_id = socket.assigns.organizer_user_id
    current_year = socket.assigns.current_year
    current_month = socket.assigns.current_month
    user_timezone = socket.assigns.user_timezone
    organizer_profile = socket.assigns.organizer_profile

    duration_minutes = get_duration_minutes(socket)
    {start_date, end_date} = display_range(current_year, current_month)

    task =
      Task.async(fn ->
        get_range_availability(
          organizer_user_id,
          start_date,
          end_date,
          user_timezone,
          organizer_profile,
          context,
          duration_minutes
        )
      end)

    socket
    |> assign(:availability_task, task)
    |> assign(:availability_task_ref, task.ref)
  end

  @doc """
  Gets calendar days for month view.

  ## Parameters
    - user_timezone: Timezone of the user viewing
    - year: Year to display
    - month: Month to display (1-12)
    - organizer_profile: Profile with booking settings
    - availability_map: Optional real availability data. Can be:
      - nil: Use business hours only (fast)
      - :loading: Show loading state
      - %{}: Use real conflict-aware availability
  """
  @spec get_calendar_days(String.t(), integer(), integer(), map() | nil, map() | atom() | nil) ::
          [map()]
  def get_calendar_days(user_timezone, year, month, organizer_profile, availability_map \\ nil) do
    if organizer_profile do
      if demo_user?(organizer_profile) do
        # Delegate to demo provider for calendar days
        Demo.get_calendar_days(user_timezone, year, month, organizer_profile, availability_map)
      else
        config = %{
          profile_id: organizer_profile.id,
          max_advance_booking_days: organizer_profile.advance_booking_days,
          min_advance_hours: organizer_profile.min_advance_hours,
          buffer_minutes: organizer_profile.buffer_minutes,
          owner_timezone: organizer_profile.timezone
        }

        Calculate.get_calendar_days(user_timezone, year, month, config, availability_map)
      end
    else
      # Return empty calendar days when profile is nil
      []
    end
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

  defp get_duration_minutes(socket) do
    cond do
      mt = socket.assigns[:meeting_type] -> mt.duration_minutes
      is_integer(socket.assigns[:duration]) -> socket.assigns[:duration]
      is_binary(socket.assigns[:duration]) -> parse_duration_minutes(socket.assigns[:duration])
      true -> 30
    end
  end

  @doc """
  Computes the 42-day display range for a calendar grid.

  Delegates to `Calculate.display_range/2` — the single source of truth
  for the calendar grid window.
  """
  @spec display_range(integer(), integer()) :: {Date.t(), Date.t()}
  defdelegate display_range(year, month), to: Calculate

  @doc """
  Gets calendar days for a week view.
  """
  @spec get_week_days(Date.t(), map(), map() | atom() | nil, String.t()) :: [map()]
  def get_week_days(
        week_start,
        organizer_profile,
        availability_map \\ nil,
        user_timezone \\ "Etc/UTC"
      ) do
    if organizer_profile do
      today = user_timezone |> DateTimeUtils.now_in_timezone() |> DateTime.to_date()

      Enum.map(0..6, fn day_offset ->
        date = Date.add(week_start, day_offset)
        date_string = Date.to_string(date)

        {is_available, is_loading} =
          cond do
            availability_map == :loading ->
              {false, true}

            is_map(availability_map) ->
              {Map.get(availability_map, date_string, false), false}

            true ->
              {day_available?(date, organizer_profile, today), false}
          end

        %{
          date: date_string,
          day_name: LocalizationHelpers.day_name_short(Date.day_of_week(date)),
          day_number: date.day,
          available: is_available,
          loading: is_loading,
          today: date == today
        }
      end)
    else
      []
    end
  end

  defp day_available?(date, organizer_profile, today) do
    is_weekday = BusinessHours.business_day?(date, organizer_profile.id)
    is_future = Date.compare(date, today) != :lt
    is_within_limit = Date.diff(date, today) <= organizer_profile.advance_booking_days

    is_weekday && is_future && is_within_limit
  end

  defp demo_user?(profile) do
    Demo.demo_profile?(profile)
  end

  @doc """
  Handles previous month navigation.
  """
  @spec handle_prev_month(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_prev_month(socket) do
    current_month = socket.assigns.current_month
    current_year = socket.assigns.current_year

    {prev_year, prev_month} =
      if current_month == 1, do: {current_year - 1, 12}, else: {current_year, current_month - 1}

    socket
    |> assign(:current_month, prev_month)
    |> assign(:current_year, prev_year)
    |> update_calendar_data()
  end

  @doc """
  Handles next month navigation.
  """
  @spec handle_next_month(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_next_month(socket) do
    current_month = socket.assigns.current_month
    current_year = socket.assigns.current_year

    {next_year, next_month} =
      if current_month == 12, do: {current_year + 1, 1}, else: {current_year, current_month + 1}

    socket
    |> assign(:current_month, next_month)
    |> assign(:current_year, next_year)
    |> update_calendar_data()
  end

  @doc """
  Handles week navigation (prev/next).

  Advances `current_week_start` by ±7 days. When the week crosses a month
  boundary, also updates month/year assigns and refetches availability.
  """
  @spec handle_week_navigation(Phoenix.LiveView.Socket.t(), :prev | :next) ::
          Phoenix.LiveView.Socket.t()
  def handle_week_navigation(socket, direction) do
    offset = if direction == :next, do: 7, else: -7
    new_week_start = Date.add(socket.assigns.current_week_start, offset)

    # Use the middle of the week as a reference for which month's availability to fetch
    reference_date = Date.add(new_week_start, 3)

    if socket.assigns.current_month != reference_date.month or
         socket.assigns.current_year != reference_date.year do
      socket
      |> assign(:current_week_start, new_week_start)
      |> assign(:current_month, reference_date.month)
      |> assign(:current_year, reference_date.year)
      |> assign(:month_availability_map, nil)
      |> assign(:availability_status, :not_loaded)
      |> fetch_month_availability_async()
    else
      assign(socket, :current_week_start, new_week_start)
    end
  end

  @doc """
  Handles timezone change.
  """
  @spec handle_timezone_change(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_timezone_change(socket, timezone) do
    socket
    |> assign(:user_timezone, timezone)
    |> update_calendar_data()
  end

  @doc """
  Handles timezone search.
  """
  @spec handle_timezone_search(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_timezone_search(socket, search_term) do
    filtered_timezones = Timezones.search(search_term)
    assign(socket, :filtered_timezones, filtered_timezones)
  end

  @doc """
  Parses slot time string to DateTime for display.
  """
  @spec parse_slot_time(String.t()) :: DateTime.t()
  def parse_slot_time(slot_string) do
    case DateTimeUtils.parse_time_string(slot_string) do
      {:ok, time} ->
        {:ok, dt} = DateTime.new(Date.utc_today(), time)
        dt

      {:error, _reason} ->
        DateTime.utc_now()
    end
  end

  defp update_calendar_data(socket) do
    %{
      current_month: current_month,
      current_year: current_year,
      user_timezone: user_timezone,
      organizer_profile: organizer_profile
    } = socket.assigns

    # Use availability map if present, otherwise nil (will use business hours only)
    availability_map = Map.get(socket.assigns, :month_availability_map)

    calendar_days =
      get_calendar_days(
        user_timezone,
        current_year,
        current_month,
        organizer_profile,
        availability_map
      )

    assign(socket, :calendar_days, calendar_days)
  end
end
