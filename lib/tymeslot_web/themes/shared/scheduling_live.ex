# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule TymeslotWeb.Themes.Shared.SchedulingLive do
  @moduledoc """
  Shared LiveView macro for scheduling themes.

  Provides all common mount/handle_params/handle_info/handle_event callbacks
  for the 4-step booking flow. Themes `use` this macro and only need to define:

  - `render/1` — wrapper component and step layout
  - `handle_theme_event/3` (optional) — for theme-specific events
  - `handle_theme_schedule_event/3` (optional) — for theme-specific schedule events

  ## Example

      defmodule MyTheme.Scheduling.Live do
        use TymeslotWeb.Themes.Shared.SchedulingLive, theme_id: "3"

        alias MyTheme.Scheduling.Wrapper

        @impl Phoenix.LiveView
        def render(assigns) do
          ~H\"""
          <Wrapper.my_wrapper ...>
            ...
          </Wrapper.my_wrapper>
          \"""
        end
      end
  """

  defmacro __using__(opts) do
    theme_id = Keyword.fetch!(opts, :theme_id)

    quote do
      use TymeslotWeb, :live_view
      require Logger

      alias TymeslotWeb.Live.Scheduling.Helpers

      alias TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponent

      alias TymeslotWeb.Themes.Shared.BookingFlow

      alias TymeslotWeb.Themes.Shared.{
        EventHandlers,
        InfoHandlers,
        LiveHelpers,
        PathHandlers,
        SchedulingInit
      }

      alias TymeslotWeb.Themes.Shared.StateMachineHelpers, as: StateMachine

      alias TymeslotWeb.Themes.Shared.Components.ErrorComponent

      @theme_id unquote(theme_id)

      @impl Phoenix.LiveView
      def mount(params, _session, socket) do
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
        new_state = StateMachine.determine_initial_state(socket.assigns[:live_action])

        LiveHelpers.handle_scheduling_params(
          socket,
          params,
          new_state,
          &handle_param_updates/2,
          &handle_state_entry/3
        )
      end

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
      def handle_info({:calendar_events_updated, _user_id, _changed_uids}, socket) do
        InfoHandlers.handle_calendar_events_updated(socket)
      end

      @impl Phoenix.LiveView
      def handle_info({:calendar_sync_complete, _user_id, _integration_id}, socket) do
        InfoHandlers.handle_calendar_events_updated(socket)
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

      @impl Phoenix.LiveView
      def handle_info({ref, {:ok, availability_map}}, socket) when is_reference(ref) do
        InfoHandlers.handle_availability_ok(socket, ref, availability_map)
      end

      @impl Phoenix.LiveView
      def handle_info({ref, {:error, reason}}, socket) when is_reference(ref) do
        InfoHandlers.handle_availability_error(socket, ref, reason)
      end

      @impl Phoenix.LiveView
      def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
        InfoHandlers.handle_availability_down(socket, ref, reason)
      end

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

      @impl Phoenix.LiveView
      def handle_event(event, params, socket) do
        handle_theme_event(event, params, socket)
      end

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
            handle_theme_schedule_event(socket, event, data)
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
          :prev_week -> {:noreply, Helpers.handle_week_navigation(socket, :prev)}
          :next_week -> {:noreply, Helpers.handle_week_navigation(socket, :next)}
        end
      end

      defp handle_schedule_navigation_events(socket, event) do
        case event do
          :back_step -> handle_state_transition(socket, :schedule, :overview)
          :next_step -> handle_state_transition(socket, :schedule, :booking)
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
          :schedule_another -> {:noreply, transition_to(socket, :overview, %{})}
          _other -> {:noreply, socket}
        end
      end

      defp maybe_assign_meeting_type(socket, duration) do
        LiveHelpers.maybe_assign_meeting_type(socket, duration)
      end

      defp assign_initial_state(socket) do
        SchedulingInit.assign_theme_state(socket, @theme_id)
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

      defp handle_state_transition(socket, current_state, next_state) do
        callbacks = %{
          validate_state_transition: &validate_state_transition/3,
          transition_to: &transition_to/3
        }

        EventHandlers.handle_state_transition(socket, current_state, next_state, callbacks)
      end

      defp transition_to(socket, new_state, params) do
        socket
        |> assign(:current_state, new_state)
        |> handle_state_entry(new_state, params)
      end

      defp validate_state_transition(socket, current_state, next_state) do
        StateMachine.validate_state_transition(socket, current_state, next_state)
      end

      # Guards against sending {:load_slots, nil} on date deselection
      defp handle_schedule_date_selection(socket, date) do
        socket =
          socket
          |> assign(:selected_date, date)
          |> assign(:selected_time, nil)
          |> assign(:loading_slots, date != nil)
          |> assign(:calendar_error, nil)

        if date, do: send(self(), {:load_slots, date})
        {:noreply, socket}
      end

      # Step navigation — shared across all themes
      defp handle_theme_event("navigate_to_step", %{"step" => step}, socket) do
        target_state =
          case Integer.parse(step) do
            {1, ""} -> :overview
            {2, ""} -> :schedule
            {3, ""} -> :booking
            {4, ""} -> :confirmation
            _other -> socket.assigns[:current_state]
          end

        if target_state != socket.assigns[:current_state] and
             StateMachine.can_navigate_to_step?(socket, target_state) do
          {:noreply, transition_to(socket, target_state, %{})}
        else
          {:noreply, socket}
        end
      end

      # Extension point for theme-specific handle_event clauses.
      # Override with multi-clause defp to handle custom events.
      defp handle_theme_event(_event, _params, socket), do: {:noreply, socket}

      # Extension point for theme-specific schedule events (e.g., month navigation).
      # Override with multi-clause defp to handle custom schedule events.
      defp handle_theme_schedule_event(socket, _event, _data), do: {:noreply, socket}

      defoverridable handle_theme_event: 3, handle_theme_schedule_event: 3
    end
  end
end
