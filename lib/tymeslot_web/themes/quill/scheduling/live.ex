defmodule TymeslotWeb.Themes.Quill.Scheduling.Live do
  @moduledoc """
  Quill theme scheduling LiveView with 4-step glassmorphism flow:
  1. Overview (duration selection)
  2. Schedule (calendar and time selection)
  3. Booking (form input)
  4. Confirmation (thank you page)
  """
  use TymeslotWeb, :live_view

  alias Tymeslot.Bookings.Validation
  alias Tymeslot.Demo.Resolver
  alias Tymeslot.Security.FormValidation
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Scheduling.Helpers
  alias TymeslotWeb.Live.Scheduling.ThemeUtils

  alias TymeslotWeb.Live.Scheduling.Handlers.{
    SlotFetchingHandlerComponent,
    TimezoneHandlerComponent
  }

  alias TymeslotWeb.Themes.Quill.Scheduling.BookingFlow
  alias TymeslotWeb.Themes.Quill.Scheduling.StateMachine

  alias TymeslotWeb.Themes.Quill.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    ErrorComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper, as: QuillThemeWrapper
  alias TymeslotWeb.Themes.Shared.SchedulingInit

  require Logger

  @impl true
  def mount(params, _session, socket) do
    # Determine initial state from route
    initial_state = StateMachine.determine_initial_state(socket.assigns.live_action)

    # Initialize state first
    socket =
      socket
      |> assign_initial_state()
      |> ThemeUtils.assign_user_timezone(params)
      |> ThemeUtils.assign_theme_with_preview(params)

    # Then handle username context (which sets meeting_types)
    socket = Helpers.handle_username_resolution(socket, params["username"])

    # Finally setup initial state
    socket = setup_initial_state(socket, initial_state, params)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Handle URL changes (back/forward navigation)
    new_state = StateMachine.determine_initial_state(socket.assigns.live_action)

    # Update theme preview mode if theme param is present
    socket =
      if Map.has_key?(params, "theme") do
        socket
        |> assign(:theme_preview, true)
        |> assign(:scheduling_theme_id, params["theme"])
      else
        socket
      end

    socket =
      socket
      |> handle_param_updates(params)
      |> assign(:current_state, new_state)
      |> handle_state_entry(new_state, params)

    {:noreply, socket}
  end

  # Handle events from step components
  @impl true
  def handle_info({:step_event, step, event, data}, socket) do
    case step do
      :overview -> handle_overview_events(socket, event, data)
      :schedule -> handle_schedule_events(socket, event, data)
      :booking -> handle_booking_events(socket, event, data)
      :confirmation -> handle_confirmation_events(socket, event, data)
      _ -> {:noreply, socket}
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

  # Handle step navigation from header
  @impl true
  def handle_event("navigate_to_step", %{"step" => step}, socket) do
    target_state =
      case String.to_integer(step) do
        1 -> :overview
        2 -> :schedule
        3 -> :booking
        4 -> :confirmation
        _ -> socket.assigns.current_state
      end

    # Only allow navigation to previous steps or current step
    if target_state != socket.assigns.current_state and
         StateMachine.can_navigate_to_step?(socket, target_state) do
      {:noreply, transition_to(socket, target_state, %{})}
    else
      {:noreply, socket}
    end
  end

  # Step-specific event handlers
  defp handle_overview_events(socket, event, data) do
    case event do
      :select_duration ->
        socket =
          socket
          |> assign(:selected_duration, data)
          |> assign(:duration, data)
          |> maybe_assign_meeting_type(data)

        {:noreply, socket}

      :next_step ->
        handle_state_transition(socket, :overview, :schedule)

      _ ->
        {:noreply, socket}
    end
  end

  defp handle_schedule_events(socket, event, data) do
    cond do
      event in [:select_date, :select_time] ->
        handle_schedule_selection_events(socket, event, data)

      event in [
        :change_timezone,
        :search_timezone,
        :toggle_timezone_dropdown,
        :close_timezone_dropdown
      ] ->
        handle_timezone_events(socket, event, data)

      event in [:prev_month, :next_month] ->
        handle_month_navigation_events(socket, event)

      event in [:back_step, :next_step] ->
        handle_schedule_navigation_events(socket, event)

      true ->
        {:noreply, socket}
    end
  end

  defp handle_schedule_selection_events(socket, event, data) do
    case event do
      :select_date ->
        handle_schedule_date_selection(socket, data)

      :select_time ->
        new_time = if socket.assigns.selected_time == data, do: nil, else: data
        {:noreply, assign(socket, :selected_time, new_time)}
    end
  end

  defp handle_timezone_events(socket, event, data) do
    case event do
      :change_timezone ->
        handle_timezone_change(socket, data)

      :search_timezone ->
        handle_timezone_search(socket, data)

      :toggle_timezone_dropdown ->
        {:noreply,
         assign(socket, :timezone_dropdown_open, !socket.assigns.timezone_dropdown_open)}

      :close_timezone_dropdown ->
        Process.send_after(self(), :close_dropdown, 150)
        {:noreply, socket}
    end
  end

  defp handle_month_navigation_events(socket, event) do
    case event do
      :prev_month ->
        handle_month_navigation(socket, :prev)

      :next_month ->
        handle_month_navigation(socket, :next)
    end
  end

  defp handle_schedule_navigation_events(socket, event) do
    case event do
      :back_step ->
        handle_state_transition(socket, :schedule, :overview)

      :next_step ->
        handle_state_transition(socket, :schedule, :booking)
    end
  end

  defp handle_booking_events(socket, event, data) do
    case event do
      :validate ->
        handle_form_validation(socket, data)

      :field_blur ->
        {:noreply, Helpers.mark_field_touched(socket, data)}

      :submit ->
        handle_booking_submission(socket, data)

      :back_step ->
        handle_state_transition(socket, :booking, :schedule)

      _ ->
        {:noreply, socket}
    end
  end

  defp handle_confirmation_events(socket, event, _data) do
    case event do
      :schedule_another ->
        {:noreply, transition_to(socket, :overview, %{})}

      _ ->
        {:noreply, socket}
    end
  end

  # Helpers to reduce nesting
  defp maybe_assign_meeting_type(socket, duration_str) do
    if socket.assigns.username_context && socket.assigns.organizer_user_id do
      case Resolver.find_by_duration_string(socket.assigns.organizer_user_id, duration_str) do
        nil -> socket
        meeting_type -> assign(socket, :meeting_type, meeting_type)
      end
    else
      socket
    end
  end

  # State machine implementation

  defp assign_initial_state(socket) do
    today = Date.utc_today()

    socket
    |> SchedulingInit.assign_base_state()
    |> assign(:duration, nil)
    |> assign(:meeting_type, nil)
    |> assign(:current_year, today.year)
    |> assign(:current_month, today.month)
    |> Helpers.setup_form_state()
    |> assign(:client_ip, nil)
    |> assign(:submission_token, nil)
    |> assign(:meeting_types, [])
  end

  defp handle_param_updates(socket, params) do
    socket
    |> maybe_assign_from_params(:duration, params["duration"])
    |> maybe_assign_from_params(:selected_date, params["date"])
    |> maybe_assign_from_params(:selected_time, params["time"])
    |> maybe_assign_from_params(:reschedule_meeting_uid, params["reschedule_meeting_uid"])
    |> assign(:is_rescheduling, params["reschedule_meeting_uid"] != nil)
    |> handle_confirmation_params(params)
  end

  defp handle_confirmation_params(socket, params) do
    if socket.assigns.live_action == :confirmation do
      socket
      |> assign(:name, URI.decode(params["name"] || "Guest"))
      |> assign(:email, params["email"] || "")
      |> assign(:meeting_uid, params["meeting_uid"] || "")
    else
      socket
    end
  end

  defp maybe_assign_from_params(socket, _key, nil), do: socket
  defp maybe_assign_from_params(socket, key, value), do: assign(socket, key, value)

  defp setup_initial_state(socket, initial_state, params) do
    if initial_state in [:overview, :schedule, :booking, :confirmation] do
      socket
      |> assign(:current_state, initial_state)
      |> handle_state_entry(initial_state, params)
    else
      socket
    end
  end

  defp handle_state_entry(socket, :schedule, params) do
    # Validate duration against meeting types if username context
    socket =
      if socket.assigns.username_context && params["duration"] do
        case Resolver.find_by_duration_string(
               socket.assigns.organizer_user_id,
               params["duration"]
             ) do
          nil ->
            socket
            |> put_flash(:error, "Invalid meeting duration")
            |> redirect(to: "/#{socket.assigns.username_context}")

          meeting_type ->
            assign(socket, :meeting_type, meeting_type)
        end
      else
        socket
      end

    # Set up calendar
    {current_year, current_month} =
      case DateTime.now(socket.assigns.user_timezone) do
        {:ok, dt} -> {dt.year, dt.month}
        _ -> {Date.utc_today().year, Date.utc_today().month}
      end

    socket
    |> assign(:current_year, current_year)
    |> assign(:current_month, current_month)
    |> assign(:duration, params["duration"] || socket.assigns.selected_duration)
  end

  defp handle_state_entry(socket, :booking, _params) do
    # Set up form and rate limiting
    client_ip = ClientIP.get(socket)
    submission_token = Base.encode64(:crypto.strong_rand_bytes(16))

    # Pre-fill form if rescheduling
    form_data =
      if socket.assigns.reschedule_meeting_uid do
        case Validation.get_meeting_for_reschedule(socket.assigns.reschedule_meeting_uid) do
          {:ok, meeting} ->
            %{
              "name" => meeting.attendee_name,
              "email" => meeting.attendee_email,
              "message" => meeting.attendee_message || ""
            }

          _ ->
            %{"name" => "", "email" => "", "message" => ""}
        end
      else
        %{"name" => "", "email" => "", "message" => ""}
      end

    socket
    |> Helpers.setup_form_state(form_data)
    |> assign(:client_ip, client_ip)
    |> assign(:submission_token, submission_token)
    |> assign(:submission_processed, false)
  end

  defp handle_state_entry(socket, _state, _params), do: socket

  # Event handlers
  defp handle_state_transition(socket, current_state, next_state) do
    case validate_state_transition(socket, current_state, next_state) do
      :ok ->
        socket = transition_to(socket, next_state, %{})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  defp transition_to(socket, new_state, _params) do
    socket
    |> assign(:current_state, new_state)
    |> handle_state_entry(new_state, %{})
  end

  defp validate_state_transition(socket, current_state, next_state) do
    StateMachine.validate_state_transition(socket, current_state, next_state)
  end

  defp handle_schedule_date_selection(socket, date) do
    socket =
      socket
      |> assign(:selected_date, date)
      |> assign(:selected_time, nil)
      |> assign(:loading_slots, true)
      |> assign(:calendar_error, nil)

    send(self(), {:load_slots, date})
    {:noreply, socket}
  end

  defp handle_timezone_change(socket, data) do
    case TimezoneHandlerComponent.handle_timezone_change(socket, data) do
      {:ok, updated_socket} -> {:noreply, updated_socket}
    end
  end

  defp handle_timezone_search(socket, params) do
    search_term =
      case params do
        %{"search" => term} -> term
        %{"value" => term} -> term
        %{"_target" => ["search"], "search" => term} -> term
        _ -> ""
      end

    socket =
      socket
      |> assign(:timezone_search, search_term)
      |> assign(:timezone_dropdown_open, true)

    {:noreply, socket}
  end

  defp handle_month_navigation(socket, direction) do
    {year, month} =
      case direction do
        :prev ->
          if socket.assigns.current_month == 1 do
            {socket.assigns.current_year - 1, 12}
          else
            {socket.assigns.current_year, socket.assigns.current_month - 1}
          end

        :next ->
          if socket.assigns.current_month == 12 do
            {socket.assigns.current_year + 1, 1}
          else
            {socket.assigns.current_year, socket.assigns.current_month + 1}
          end
      end

    socket =
      socket
      |> assign(:current_year, year)
      |> assign(:current_month, month)
      |> assign(:selected_date, nil)
      |> assign(:selected_time, nil)
      |> assign(:available_slots, [])

    {:noreply, socket}
  end

  defp handle_form_validation(socket, booking_params) do
    BookingFlow.handle_form_validation(socket, booking_params)
  end

  defp handle_booking_submission(socket, booking_params) do
    # Keep form assignment/local validation here to preserve behavior
    case FormValidation.validate_booking_form(booking_params) do
      {:ok, sanitized_params} ->
        form = to_form(sanitized_params)
        socket = socket |> assign(:form, form) |> assign(:validation_errors, [])
        BookingFlow.process_booking_submission(socket, &transition_to/3)

      {:error, errors} ->
        {:ok, sanitized_params} = FormValidation.sanitize_booking_params(booking_params)
        form = to_form(sanitized_params)

        socket =
          socket
          |> assign(:form, form)
          |> assign(:validation_errors, errors)
          |> put_flash(:error, "Please correct the errors below.")

        {:noreply, socket}
    end
  end

  # Template rendering - delegates to theme-specific step components
  @impl true
  def render(assigns) do
    ~H"""
    <QuillThemeWrapper.quill_wrapper
      custom_css={assigns[:custom_css]}
      theme_customization={assigns[:theme_customization]}
    >
      <%= if assigns[:scheduling_error_message] do %>
        <.live_component
          module={ErrorComponent}
          id="scheduling-error"
          message={@scheduling_error_message}
          reason={assigns[:scheduling_error_reason]}
        />
      <% else %>
        <%= case assigns.current_state do %>
          <% :overview -> %>
            <.live_component module={OverviewComponent} id="overview-step" {assigns} />
          <% :schedule -> %>
            <.live_component module={ScheduleComponent} id="schedule-step" {assigns} />
          <% :booking -> %>
            <.live_component module={BookingComponent} id="booking-step" {assigns} />
          <% :confirmation -> %>
            <.live_component module={ConfirmationComponent} id="confirmation-step" {assigns} />
          <% _ -> %>
            <.live_component module={OverviewComponent} id="overview-step" {assigns} />
        <% end %>
      <% end %>
    </QuillThemeWrapper.quill_wrapper>
    """
  end
end
