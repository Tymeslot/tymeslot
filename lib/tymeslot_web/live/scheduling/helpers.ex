defmodule TymeslotWeb.Live.Scheduling.Helpers do
  @moduledoc """
  Shared helper functions for the scheduling flow.
  Contains common logic used across multiple scheduling components.
  """

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Demo.{AvailabilityGenerator, Resolver}
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Security.FormValidation
  alias Tymeslot.TemplateDemo.Context
  alias Tymeslot.Utils.{DateTimeUtils, TimezoneUtils}
  alias TymeslotWeb.Components.FormSystem
  alias TymeslotWeb.Helpers.ClientIP

  import Phoenix.Component, only: [assign: 3]

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

    case Resolver.resolve_organizer_context(username) do
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

  defdelegate setup_form_state(socket, form_data \\ %{}), to: FormSystem
  defdelegate assign_form_errors(socket, errors), to: FormSystem

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
    ip = ClientIP.get(socket)
    assign(socket, :client_ip, ip)
  end

  @doc """
  Validates if form is complete and valid.
  """
  @spec form_valid?(Phoenix.HTML.Form.t()) :: boolean()
  def form_valid?(form) do
    case FormValidation.validate_booking_form(form.source) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Gets available slots for a specific date.
  """
  @spec get_available_slots(
          String.t(),
          String.t(),
          String.t(),
          integer(),
          map(),
          Phoenix.LiveView.Socket.t() | nil
        ) :: {:ok, [map()]} | {:error, any()}
  def get_available_slots(
        date_string,
        duration,
        user_timezone,
        organizer_user_id,
        organizer_profile,
        socket \\ nil
      ) do
    with {:ok, date} <- Date.from_iso8601(date_string),
         {:ok, owner_timezone} <- get_owner_timezone(organizer_profile) do
      # Check if this is a demo user
      if demo_user?(organizer_profile) || (socket && Context.demo_mode?(socket)) do
        # Generate synthetic availability for demo users
        duration_minutes = parse_duration_minutes(duration)

        AvailabilityGenerator.generate_available_slots(
          date,
          duration_minutes,
          user_timezone,
          owner_timezone
        )
      else
        # Regular flow for real users
        with {:ok, events} <-
               Calendar.get_calendar_events_from_socket(
                 date,
                 organizer_user_id,
                 socket
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

  @doc """
  Gets calendar days for month view.
  """
  @spec get_calendar_days(String.t(), integer(), integer(), map() | nil) :: [map()]
  def get_calendar_days(user_timezone, year, month, organizer_profile) do
    if organizer_profile do
      if demo_user?(organizer_profile) do
        # Generate calendar days for demo users
        generate_demo_calendar_days(user_timezone, year, month, organizer_profile)
      else
        config = %{
          profile_id: organizer_profile.id,
          max_advance_booking_days: organizer_profile.advance_booking_days,
          min_advance_hours: organizer_profile.min_advance_hours,
          buffer_minutes: organizer_profile.buffer_minutes
        }

        Calculate.get_calendar_days(user_timezone, year, month, config)
      end
    else
      # Return empty calendar days when profile is nil
      []
    end
  end

  defp generate_demo_calendar_days(user_timezone, year, month, organizer_profile) do
    # Get the first and last day of the month
    {:ok, first_day} = Date.new(year, month, 1)
    last_day = Date.end_of_month(first_day)

    # Generate calendar days
    Enum.map(Date.range(first_day, last_day), fn date ->
      is_available =
        AvailabilityGenerator.date_available?(date, organizer_profile, user_timezone)

      %{
        date: Date.to_string(date),
        day: date.day,
        available: is_available,
        past: Date.compare(date, Date.utc_today()) == :lt,
        today: date == Date.utc_today(),
        current_month: date.month == month
      }
    end)
  end

  @doc """
  Groups time slots by period of day.
  """
  @spec group_slots_by_period([map()]) :: [{String.t(), [map()]}]
  def group_slots_by_period(slots) do
    grouped = DateTimeUtils.group_slots_by_period(slots)

    [
      {"Night", Map.get(grouped, "Night", [])},
      {"Morning", Map.get(grouped, "Morning", [])},
      {"Afternoon", Map.get(grouped, "Afternoon", [])},
      {"Evening", Map.get(grouped, "Evening", [])}
    ]
  end

  @doc """
  Parses slot time string to DateTime for display.
  """
  @spec parse_slot_time(String.t()) :: DateTime.t()
  def parse_slot_time(slot_string) do
    case DateTimeUtils.parse_slot_time(slot_string) do
      {:ok, time} ->
        {:ok, dt} = DateTime.new(Date.utc_today(), time)
        dt

      {:error, _} ->
        DateTime.utc_now()
    end
  end

  @doc """
  Formats booking datetime for display.
  """
  @spec format_booking_datetime(String.t() | any(), String.t() | any(), String.t() | any()) ::
          String.t()
  def format_booking_datetime(date, time, timezone)
      when is_binary(date) and is_binary(time) and is_binary(timezone) do
    # Handle both ISO date strings and Date structs
    with {:ok, date_struct} <- parse_date(date),
         # Ensure time has seconds
         time_string <- ensure_time_format(time),
         {:ok, time_obj} <- Time.from_iso8601(time_string),
         {:ok, naive_dt} <- NaiveDateTime.new(date_struct, time_obj),
         {:ok, dt} <- DateTime.from_naive(naive_dt, timezone) do
      Elixir.Calendar.strftime(dt, "%A, %d %B %Y at %H:%M %Z")
    else
      _error ->
        # Fallback formatting
        "#{date} at #{time}"
    end
  end

  def format_booking_datetime(_date, _time, _timezone), do: "Invalid date/time"

  defp parse_date(date) when is_binary(date), do: Date.from_iso8601(date)

  defp ensure_time_format(time) when is_binary(time) do
    case String.split(time, ":") do
      [_h, _m, _s] -> time
      [_h, _m] -> time <> ":00"
      _ -> time
    end
  end

  @doc """
  Gets month and year display string.
  """
  @spec get_month_year_display(integer(), integer()) :: String.t()
  def get_month_year_display(year, month) do
    month_names = [
      "January",
      "February",
      "March",
      "April",
      "May",
      "June",
      "July",
      "August",
      "September",
      "October",
      "November",
      "December"
    ]

    month_name = Enum.at(month_names, month - 1)
    "#{month_name} #{year}"
  end

  @doc """
  Checks if previous month navigation should be disabled.
  """
  @spec prev_month_disabled?(integer(), integer(), String.t()) :: boolean()
  def prev_month_disabled?(current_year, current_month, user_timezone) do
    today =
      case DateTime.now(user_timezone) do
        {:ok, dt} -> DateTime.to_date(dt)
        _ -> Date.utc_today()
      end

    current_year < today.year || (current_year == today.year && current_month <= today.month)
  end

  @doc """
  Checks if next month navigation should be disabled.
  """
  @spec next_month_disabled?(integer(), integer(), String.t()) :: boolean()
  def next_month_disabled?(current_year, current_month, user_timezone) do
    today =
      case DateTime.now(user_timezone) do
        {:ok, dt} -> DateTime.to_date(dt)
        _ -> Date.utc_today()
      end

    max_advance_booking_days =
      Application.get_env(:tymeslot, :scheduling)[:max_advance_booking_days] || 90

    max_booking_date = Date.add(today, max_advance_booking_days)

    next_month_first_day =
      if current_month == 12 do
        Date.new!(current_year + 1, 1, 1)
      else
        Date.new!(current_year, current_month + 1, 1)
      end

    Date.compare(next_month_first_day, max_booking_date) == :gt
  end

  # Private helper functions

  defp get_owner_timezone(organizer_profile) do
    {:ok, organizer_profile.timezone || "Europe/Kyiv"}
  end

  defp demo_user?(profile) do
    profile && profile.id in [999_001, 999_002]
  end

  defp parse_duration_minutes(duration) do
    case duration do
      "15min" -> 15
      "30min" -> 30
      _ -> 30
    end
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
    filtered_timezones = TimezoneUtils.get_filtered_timezone_options(search_term)
    assign(socket, :filtered_timezones, filtered_timezones)
  end

  defp update_calendar_data(socket) do
    %{
      current_month: current_month,
      current_year: current_year,
      user_timezone: user_timezone,
      organizer_profile: organizer_profile
    } = socket.assigns

    calendar_days =
      get_calendar_days(user_timezone, current_year, current_month, organizer_profile)

    assign(socket, :calendar_days, calendar_days)
  end
end
