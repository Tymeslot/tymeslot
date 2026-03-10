defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Live do
  @moduledoc """
  Rhythm theme scheduling LiveView with 4-slide flow:
  1. Overview (duration selection)
  2. Schedule (date/time selection)
  3. Booking (contact form)
  4. Confirmation (thank you page)
  """
  use TymeslotWeb, :live_view
  require Logger

  alias TymeslotWeb.Live.Scheduling.Helpers

  alias TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponent

  alias TymeslotWeb.Themes.Rhythm.Scheduling.StateMachine
  alias TymeslotWeb.Themes.Shared.BookingFlow

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper, as: RhythmThemeWrapper

  alias TymeslotWeb.Themes.Shared.{
    EventHandlers,
    InfoHandlers,
    LiveHelpers,
    PathHandlers,
    SchedulingInit
  }

  alias TymeslotWeb.Themes.Shared.Components.ErrorComponent

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    # Determine initial state from route
    initial_state = StateMachine.determine_initial_state(socket.assigns[:live_action])

    socket =
      LiveHelpers.mount_scheduling_view(
        socket,
        params,
        initial_state,
        &assign_initial_state/1,
        &setup_initial_state/3
      )

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    # Handle URL changes (back/forward navigation)
    new_state = StateMachine.determine_initial_state(socket.assigns[:live_action])

    LiveHelpers.handle_scheduling_params(
      socket,
      params,
      new_state,
      &handle_param_updates/2,
      &handle_state_entry/3
    )
  end

  # Info handlers
  @impl Phoenix.LiveView
  def handle_info({:step_event, step, event, data}, socket) do
    case step do
      :overview -> handle_overview_events(socket, event, data)
      :schedule -> handle_schedule_events(socket, event, data)
      :booking -> handle_booking_events(socket, event, data)
      :confirmation -> handle_confirmation_events(socket, event, data)
      _other -> {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_info(:close_dropdown, socket), do: InfoHandlers.handle_close_dropdown(socket)

  @impl Phoenix.LiveView
  def handle_info({:fetch_available_slots, date, duration, timezone}, socket) do
    InfoHandlers.handle_fetch_available_slots(socket, date, duration, timezone)
  end

  @impl Phoenix.LiveView
  def handle_info({:load_slots, date}, socket) do
    InfoHandlers.handle_load_slots(socket, date)
  end

  # Handle month availability fetch completion (success)
  @impl Phoenix.LiveView
  def handle_info({ref, {:ok, availability_map}}, socket) when is_reference(ref) do
    InfoHandlers.handle_availability_ok(socket, ref, availability_map)
  end

  # Handle month availability fetch completion (error)
  @impl Phoenix.LiveView
  def handle_info({ref, {:error, reason}}, socket) when is_reference(ref) do
    InfoHandlers.handle_availability_error(socket, ref, reason)
  end

  # Handle task crash or timeout
  @impl Phoenix.LiveView
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    InfoHandlers.handle_availability_down(socket, ref, reason)
  end

  # Event handlers
  @impl Phoenix.LiveView
  def handle_event("toggle_language_dropdown", _params, socket) do
    EventHandlers.handle_toggle_language_dropdown(socket)
  end

  @impl Phoenix.LiveView
  def handle_event("close_language_dropdown", _params, socket) do
    EventHandlers.handle_close_language_dropdown(socket)
  end

  @impl Phoenix.LiveView
  def handle_event("change_locale", %{"locale" => locale}, socket) do
    EventHandlers.handle_change_locale(socket, locale, PathHandlers)
  end

  # Step-specific event handlers
  defp handle_overview_events(socket, event, data) do
    callbacks = %{
      maybe_assign_meeting_type: &maybe_assign_meeting_type/2,
      validate_state_transition: &validate_state_transition/3,
      transition_to: &transition_to/3
    }

    EventHandlers.handle_overview_events(socket, event, data, callbacks)
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

      event in [:prev_week, :next_week] ->
        handle_week_navigation_events(socket, event)

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
        new_time = if socket.assigns[:selected_time] == data, do: nil, else: data
        {:noreply, assign(socket, :selected_time, new_time)}
    end
  end

  defp handle_timezone_events(socket, event, data) do
    callbacks = %{
      timezone_handler_component: TimezoneHandlerComponent,
      handle_timezone_search: &EventHandlers.handle_timezone_search/2
    }

    EventHandlers.handle_timezone_events(socket, event, data, callbacks)
  end

  defp handle_week_navigation_events(socket, event) do
    case event do
      :prev_week ->
        {:noreply, Helpers.handle_week_navigation(socket, :prev)}

      :next_week ->
        {:noreply, Helpers.handle_week_navigation(socket, :next)}
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
        BookingFlow.handle_form_validation(socket, data)

      :field_blur ->
        {:noreply, Helpers.mark_field_touched(socket, data)}

      :submit ->
        BookingFlow.submit_booking(socket, data, &transition_to/3)

      :back_step ->
        handle_state_transition(socket, :booking, :schedule)

      _other ->
        {:noreply, socket}
    end
  end

  defp handle_confirmation_events(socket, event, _data) do
    case event do
      :schedule_another ->
        {:noreply, transition_to(socket, :overview, %{})}

      _other ->
        {:noreply, socket}
    end
  end

  # Helpers to reduce nesting
  defp maybe_assign_meeting_type(socket, duration) do
    LiveHelpers.maybe_assign_meeting_type(socket, duration)
  end

  # State machine implementation

  defp assign_initial_state(socket) do
    SchedulingInit.assign_theme_state(socket, "2")
  end

  defp handle_param_updates(socket, params) do
    LiveHelpers.handle_param_updates(socket, params)
  end

  defp setup_initial_state(socket, initial_state, params) do
    LiveHelpers.setup_initial_state(socket, initial_state, params, &handle_state_entry/3)
  end

  defp handle_state_entry(socket, :schedule, params) do
    LiveHelpers.handle_schedule_entry(socket, params)
  end

  defp handle_state_entry(socket, :booking, params) do
    LiveHelpers.handle_booking_entry(socket, params)
  end

  defp handle_state_entry(socket, _state, _params), do: socket

  # Event handlers
  defp handle_state_transition(socket, current_state, next_state) do
    callbacks = %{
      validate_state_transition: &validate_state_transition/3,
      transition_to: &transition_to/3
    }

    EventHandlers.handle_state_transition(socket, current_state, next_state, callbacks)
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

    if date do
      send(self(), {:load_slots, date})
    end

    {:noreply, socket}
  end

  # Template rendering - delegates to theme-specific step components
  @impl Phoenix.LiveView
  def render(assigns) do
    # Extract organizer user ID safely
    organizer_user_id =
      case assigns[:organizer_profile] do
        %{user_id: user_id} -> user_id
        _other -> nil
      end

    assigns = assign(assigns, :organizer_user_id, organizer_user_id)

    ~H"""
    <RhythmThemeWrapper.rhythm_wrapper
      custom_css={assigns[:custom_css]}
      theme_customization={assigns[:theme_customization]}
      locale={assigns[:locale]}
      language_dropdown_open={assigns[:language_dropdown_open]}
      current_state={assigns[:current_state]}
      organizer_user_id={@organizer_user_id}
      should_show_branding={assigns[:should_show_branding]}
    >
      <%= if assigns[:scheduling_error_message] do %>
        <.live_component
          module={ErrorComponent}
          id="scheduling-error"
          message={@scheduling_error_message}
          reason={assigns[:scheduling_error_reason]}
        />
      <% else %>
        <%= case assigns[:current_state] || :overview do %>
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
    </RhythmThemeWrapper.rhythm_wrapper>
    """
  end
end
