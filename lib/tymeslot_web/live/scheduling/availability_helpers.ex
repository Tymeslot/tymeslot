defmodule TymeslotWeb.Live.Scheduling.AvailabilityHelpers do
  @moduledoc """
  Availability calculation and fetch orchestration for the scheduling flow.

  Owns the slot lookup for a single date, the cached range query that
  powers the calendar grid, and the sync/async fetch task lifecycle.
  """

  alias Phoenix.Component
  alias Tymeslot.Availability.{Calculate, TimeSlots}
  alias Tymeslot.Demo
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
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
      Calculate.display_range(socket.assigns.current_year, socket.assigns.current_month)

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
    {start_date, end_date} = Calculate.display_range(current_year, current_month)

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
end
