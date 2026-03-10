defmodule TymeslotWeb.Themes.Quill.Scheduling.Live do
  @moduledoc """
  Quill theme scheduling LiveView with 4-step glassmorphism flow:
  1. Overview (duration selection)
  2. Schedule (calendar and time selection)
  3. Booking (form input)
  4. Confirmation (thank you page)
  """
  use TymeslotWeb, :live_view
  require Logger

  alias TymeslotWeb.Live.Scheduling.Helpers

  alias TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponent

  alias TymeslotWeb.Themes.Quill.Scheduling.StateMachine
  alias TymeslotWeb.Themes.Shared.BookingFlow

  alias TymeslotWeb.Themes.Quill.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Shared.Components.ErrorComponent

  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper, as: QuillThemeWrapper

  alias TymeslotWeb.Themes.Shared.{
    EventHandlers,
    InfoHandlers,
    LiveHelpers,
    PathHandlers,
    SchedulingInit
  }

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

  # Handle step navigation from header
  @impl Phoenix.LiveView
  def handle_event("navigate_to_step", %{"step" => step}, socket) do
    target_state =
      case String.to_integer(step) do
        1 -> :overview
        2 -> :schedule
        3 -> :booking
        4 -> :confirmation
        _other -> socket.assigns[:current_state]
      end

    # Only allow navigation to previous steps or current step
    if target_state != socket.assigns[:current_state] and
         StateMachine.can_navigate_to_step?(socket, target_state) do
      {:noreply, transition_to(socket, target_state, %{})}
    else
      {:noreply, socket}
    end
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

      event in [:prev_month, :next_month] ->
        handle_month_navigation_events(socket, event)

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

  defp handle_month_navigation_events(socket, event) do
    case event do
      :prev_month ->
        {:noreply, handle_month_navigation(socket, :prev)}

      :next_month ->
        {:noreply, handle_month_navigation(socket, :next)}
    end
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
        handle_form_validation(socket, data)

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
    SchedulingInit.assign_theme_state(socket, "1")
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

    send(self(), {:load_slots, date})
    {:noreply, socket}
  end

  defp handle_month_navigation(socket, direction) do
    {year, month} =
      case direction do
        :prev ->
          if socket.assigns[:current_month] == 1 do
            {socket.assigns[:current_year] - 1, 12}
          else
            {socket.assigns[:current_year], socket.assigns[:current_month] - 1}
          end

        :next ->
          if socket.assigns[:current_month] == 12 do
            {socket.assigns[:current_year] + 1, 1}
          else
            {socket.assigns[:current_year], socket.assigns[:current_month] + 1}
          end
      end

    socket =
      socket
      |> assign(:current_year, year)
      |> assign(:current_month, month)
      |> assign(:selected_date, nil)
      |> assign(:selected_time, nil)
      |> assign(:available_slots, [])
      |> assign(:month_availability_map, nil)
      |> assign(:availability_status, :not_loaded)

    # Trigger availability refresh for new month
    Helpers.fetch_month_availability_async(socket)
  end

  defp handle_form_validation(socket, booking_params) do
    BookingFlow.handle_form_validation(socket, booking_params)
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
    <QuillThemeWrapper.quill_wrapper
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
    </QuillThemeWrapper.quill_wrapper>
    """
  end
end
