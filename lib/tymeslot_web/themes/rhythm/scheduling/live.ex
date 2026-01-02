defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Live do
  @moduledoc """
  Rhythm theme scheduling LiveView with 4-slide flow:
  1. Overview (duration selection)
  2. Schedule (date/time selection)
  3. Booking (contact form)
  4. Confirmation (thank you page)
  """
  use TymeslotWeb, :live_view

  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Demo.Resolver
  alias Tymeslot.TemplateDemo.Context
  alias Tymeslot.Themes.Theme
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingSubmissionHandlerComponent

  alias TymeslotWeb.Live.Scheduling.Handlers.{
    SlotFetchingHandlerComponent,
    TimezoneHandlerComponent
  }

  alias TymeslotWeb.Live.Scheduling.Helpers
  alias TymeslotWeb.Live.Scheduling.ThemeUtils
  alias TymeslotWeb.Themes.Shared.SchedulingInit

  require Logger

  @impl true
  def mount(params, _session, socket) do
    # Determine initial state based on live_action
    initial_state = Theme.get_initial_state("2", socket.assigns.live_action)

    Logger.debug(
      "Rhythm theme mounting with live_action: #{inspect(socket.assigns.live_action)}, initial_state: #{inspect(initial_state)}"
    )

    # Initialize state first
    socket =
      socket
      |> assign_initial_state()
      |> ThemeUtils.assign_user_timezone(params)
      |> ThemeUtils.assign_theme()

    # Then handle username context (which sets meeting_types)
    socket = Helpers.handle_username_resolution(socket, params["username"])

    # Finally setup initial state - override with correct state
    socket = setup_initial_state(socket, initial_state || :overview, params)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Handle URL changes (back/forward navigation)
    new_state = Theme.get_initial_state("2", socket.assigns.live_action)
    socket = transition_to(socket, new_state, params)
    {:noreply, socket}
  end

  # Handle events from step components
  @impl true
  def handle_info({:step_event, step, event, data} = msg, socket) do
    Logger.debug("RhythmSchedulingLive handle_info received step_event: #{inspect(msg)}")

    case step do
      :overview ->
        handle_overview_events(socket, event, data)

      :schedule ->
        handle_schedule_events(socket, event, data)

      :booking ->
        handle_booking_events(socket, event, data)

      :confirmation ->
        handle_confirmation_events(socket, event, data)

      # Handle legacy state
      :schedule_and_book ->
        handle_overview_events(socket, event, data)

      _ ->
        Logger.debug("Unknown step in handle_info: #{inspect(step)}")
        {:noreply, socket}
    end
  end

  # Other info handlers
  @impl true
  def handle_info(:close_dropdown, socket) do
    {:noreply, assign(socket, :timezone_dropdown_open, false)}
  end

  def handle_info({:fetch_available_slots, date, duration, timezone}, socket) do
    case SlotFetchingHandlerComponent.fetch_available_slots(socket, date, duration, timezone) do
      {:ok, updated_socket} -> {:noreply, updated_socket}
      {:error, updated_socket} -> {:noreply, updated_socket}
    end
  end

  def handle_info({:load_slots, date}, socket) do
    case SlotFetchingHandlerComponent.load_slots(socket, date) do
      {:ok, updated_socket} -> {:noreply, updated_socket}
    end
  end

  # Handle overview slide events
  defp handle_overview_events(socket, event, data) do
    Logger.debug(
      "RhythmSchedulingLive handle_overview_events called with event: #{inspect(event)}, data: #{inspect(data)}"
    )

    case event do
      :select_duration ->
        Logger.debug("Processing select_duration event with data: #{inspect(data)}")

        # Data is a map with duration key
        duration = Map.get(data, :duration)

        socket = update_socket_for_duration(socket, duration)

        {:noreply, socket}

      :next_step ->
        Logger.debug("Processing next_step event, transitioning to :schedule")
        socket = transition_to(socket, :schedule, %{})
        {:noreply, socket}

      _ ->
        Logger.debug("Unknown event in handle_overview_events: #{inspect(event)}")
        {:noreply, socket}
    end
  end

  # Handle schedule slide events
  defp handle_schedule_events(socket, event, data) do
    case event do
      :select_date ->
        handle_schedule_date_selection(socket, data)

      :select_time ->
        handle_schedule_time_selection(socket, data)

      :change_timezone ->
        handle_timezone_change(socket, data)

      :toggle_timezone_dropdown ->
        handle_timezone_dropdown_toggle(socket)

      :close_timezone_dropdown ->
        handle_timezone_dropdown_close(socket)

      :next_step ->
        handle_schedule_next_step(socket)

      :prev_step ->
        handle_schedule_prev_step(socket)

      _ ->
        {:noreply, socket}
    end
  end

  defp handle_schedule_time_selection(socket, data) do
    # Extract time from data map
    time = Map.get(data, :time)
    socket = assign(socket, :selected_time, time)
    {:noreply, socket}
  end

  defp handle_timezone_dropdown_toggle(socket) do
    current_state = socket.assigns.timezone_dropdown_open || false
    socket = assign(socket, :timezone_dropdown_open, !current_state)
    {:noreply, socket}
  end

  defp handle_timezone_dropdown_close(socket) do
    socket = assign(socket, :timezone_dropdown_open, false)
    {:noreply, socket}
  end

  defp handle_schedule_next_step(socket) do
    socket = transition_to(socket, :booking, %{})
    {:noreply, socket}
  end

  defp handle_schedule_prev_step(socket) do
    socket = transition_to(socket, :overview, %{})
    {:noreply, socket}
  end

  defp handle_schedule_date_selection(socket, data) do
    # Extract date from data map
    date = Map.get(data, :date)

    socket =
      socket
      |> assign(:selected_date, date)
      |> assign(:selected_time, nil)
      |> assign(:loading_slots, true)
      |> assign(:calendar_error, nil)

    # Only load slots if date is not nil
    if date do
      send(self(), {:load_slots, date})
    end

    {:noreply, socket}
  end

  # Handle booking slide events
  defp handle_booking_events(socket, event, data) do
    case event do
      :submit_booking ->
        # Process the booking through the orchestrator
        process_booking_submission(socket, data)

      :prev_step ->
        socket = transition_to(socket, :schedule, %{})
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # Handle confirmation slide events
  defp handle_confirmation_events(socket, event, _data) do
    case event do
      :schedule_another ->
        path =
          if socket.assigns.username_context,
            do: "/#{socket.assigns.username_context}",
            else: "/"

        {:noreply, push_navigate(socket, to: path)}

      _ ->
        {:noreply, socket}
    end
  end

  # Helpers to reduce nesting
  defp update_socket_for_duration(socket, duration) do
    socket
    |> assign(:selected_duration, duration)
    |> assign(:duration, "#{duration}min")
    |> maybe_assign_meeting_type("#{duration}min")
  end

  defp maybe_assign_meeting_type(socket, duration_str) do
    if socket.assigns.username_context && socket.assigns.organizer_user_id do
      case Resolver.find_by_duration_string(socket.assigns.organizer_user_id, duration_str) do
        nil ->
          Logger.debug("No meeting type found for duration: #{duration_str}")
          socket

        meeting_type ->
          Logger.debug("Found meeting type: #{inspect(meeting_type)}")
          assign(socket, :meeting_type, meeting_type)
      end
    else
      Logger.debug("No username context or organizer_user_id")
      socket
    end
  end

  defp process_booking_submission(socket, form_data) do
    Logger.debug("Processing booking submission with form_data: #{inspect(form_data)}")

    Logger.debug(
      "Socket assigns - selected_time: #{inspect(socket.assigns[:selected_time])}, selected_date: #{inspect(socket.assigns[:selected_date])}, duration: #{inspect(socket.assigns[:selected_duration])}"
    )

    socket =
      socket
      |> assign(:validation_errors, [])
      |> assign(:attendee_name, form_data["name"])
      |> assign(:attendee_email, form_data["email"])
      |> assign(:attendee_message, form_data["message"])
      |> assign(:submitting, true)
      |> assign(:submission_processed, true)

    params = %{
      form_data: form_data,
      meeting_params: %{
        organizer_user_id: socket.assigns.organizer_user_id,
        date: socket.assigns.selected_date,
        time: socket.assigns.selected_time,
        duration: socket.assigns.selected_duration,
        user_timezone: socket.assigns.user_timezone
      }
    }

    Logger.debug("Booking params being sent to orchestrator: #{inspect(params)}")

    opts = [
      is_rescheduling: Map.get(socket.assigns, :is_rescheduling, false),
      reschedule_uid: Map.get(socket.assigns, :reschedule_meeting_uid),
      client_ip: ClientIP.get(socket)
    ]

    if Context.demo_mode?(socket) do
      handle_demo_booking(socket, form_data)
    else
      handle_real_booking(socket, form_data, {params, opts})
    end
  end

  defp handle_demo_booking(socket, form_data) do
    Logger.info("Demo mode: Skipping actual booking creation, showing confirmation")

    demo_meeting_uid = "demo-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    socket =
      socket
      |> assign(:name, form_data["name"])
      |> assign(:email, form_data["email"])
      |> assign(:meeting_uid, demo_meeting_uid)
      |> assign(:is_rescheduling, false)
      |> assign(:reschedule_meeting_uid, nil)
      |> transition_to(:confirmation, %{})
      |> put_flash(
        :info,
        "Demo: Booking confirmed! (Using the app, you would receive a confirmation email)"
      )

    {:noreply, socket}
  end

  defp handle_real_booking(socket, form_data, {params, opts}) do
    case Orchestrator.submit_booking(params, opts) do
      {:ok, meeting} -> handle_booking_success(socket, meeting, form_data)
      {:error, errors} when is_list(errors) -> handle_booking_validation_errors(socket, errors)
      {:error, reason} -> handle_booking_error(socket, reason)
    end
  end

  defp handle_booking_success(socket, meeting, form_data) do
    {:ok, socket} =
      BookingSubmissionHandlerComponent.handle_booking_success(
        socket,
        meeting,
        form_data
      )

    socket =
      socket
      |> assign(:name, form_data["name"])
      |> assign(:email, form_data["email"])
      |> assign(:submitting, false)
      |> transition_to(:confirmation, %{})

    {:noreply, socket}
  end

  defp handle_booking_validation_errors(socket, errors) do
    Logger.error("Validation errors occurred: #{inspect(errors)}")

    socket =
      socket
      |> assign(:validation_errors, errors)
      |> assign(:submitting, false)
      |> assign(:submission_processed, false)
      |> clear_flash()

    {:noreply, socket}
  end

  defp handle_booking_error(socket, reason) do
    Logger.error("Booking submission failed with reason: #{inspect(reason)}")

    {:error, error_socket} =
      BookingSubmissionHandlerComponent.handle_booking_error(socket, reason)

    {:noreply, error_socket}
  end

  defp assign_initial_state(socket) do
    existing_customization = Map.get(socket.assigns, :theme_customization)
    existing_custom_css = Map.get(socket.assigns, :custom_css, "")
    existing_has_custom = Map.get(socket.assigns, :has_custom_theme, false)

    socket
    |> SchedulingInit.assign_base_state()
    |> assign(:attendee_name, nil)
    |> assign(:attendee_email, nil)
    |> assign(:attendee_message, nil)
    |> assign(:validation_errors, [])
    |> assign(:has_custom_theme, existing_has_custom)
    |> assign(:theme_customization, existing_customization)
    |> assign(:custom_css, existing_custom_css)
  end

  defp setup_initial_state(socket, initial_state, _params) do
    assign(socket, :current_state, initial_state)
  end

  defp transition_to(socket, new_state, _params) do
    assign(socket, :current_state, new_state)
  end

  defp handle_timezone_change(socket, data) do
    case TimezoneHandlerComponent.handle_timezone_change(socket, data) do
      {:ok, updated_socket} -> {:noreply, updated_socket}
    end
  end

  # Template rendering - uses slides component for main flow, confirmation for final step
  @impl true
  def render(assigns) do
    Logger.debug(
      "Rhythm theme rendering with current_state: #{inspect(assigns.current_state)}, selected_duration: #{inspect(assigns[:selected_duration])}"
    )

    ~H"""
    <TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper.rhythm_wrapper
      custom_css={@custom_css}
      theme_customization={@theme_customization}
    >
      <%= if assigns[:scheduling_error_message] do %>
        <div class="h-[70vh] flex items-center justify-center px-4">
          <div
            class="text-center w-full max-w-lg mx-auto p-6 md:p-8 rounded-xl shadow-xl"
            style="background: rgba(0,0,0,0.65); backdrop-filter: blur(6px); -webkit-backdrop-filter: blur(6px); border: 1px solid rgba(255,255,255,0.25);"
          >
            <svg
              class="w-12 h-12 mx-auto mb-4 text-white"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 9v2m0 4h.01M4.93 4.93l14.14 14.14M12 2a10 10 0 100 20 10 10 0 000-20z"
              />
            </svg>
            <h1 class="text-2xl md:text-3xl font-semibold mb-3" style="color: #ffffff;">
              We can’t show this scheduling page yet
            </h1>
            <p class="mb-3" style="color: rgba(255,255,255,0.95);">{@scheduling_error_message}</p>
            <p class="text-sm" style="color: rgba(255,255,255,0.85);">
              If you are the organizer, please connect a calendar in your dashboard.
            </p>
          </div>
        </div>
      <% else %>
        <%= case @current_state do %>
          <% :overview -> %>
            <.live_component
              module={TymeslotWeb.Themes.Rhythm.Scheduling.Components.OverviewComponent}
              id="rhythm-overview"
              {assigns}
            />
          <% :schedule -> %>
            <.live_component
              module={TymeslotWeb.Themes.Rhythm.Scheduling.Components.ScheduleComponent}
              id="rhythm-schedule"
              {assigns}
            />
          <% :booking -> %>
            <.live_component
              module={TymeslotWeb.Themes.Rhythm.Scheduling.Components.BookingComponent}
              id="rhythm-booking"
              {assigns}
            />
          <% :confirmation -> %>
            <.live_component
              module={TymeslotWeb.Themes.Rhythm.Scheduling.Components.ConfirmationComponent}
              id="confirmation-step"
              {assigns}
            />
          <% _ -> %>
            <.live_component
              module={TymeslotWeb.Themes.Rhythm.Scheduling.Components.OverviewComponent}
              id="rhythm-overview"
              {assigns}
            />
        <% end %>
      <% end %>
    </TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper.rhythm_wrapper>
    """
  end
end
