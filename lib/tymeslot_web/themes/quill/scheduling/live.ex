defmodule TymeslotWeb.Themes.Quill.Scheduling.Live do
  @moduledoc """
  Quill theme scheduling LiveView with 4-step glassmorphism flow:
  1. Overview (duration selection)
  2. Schedule (calendar and time selection)
  3. Booking (form input)
  4. Confirmation (thank you page)
  """
  use TymeslotWeb.Themes.Shared.SchedulingLive, theme_id: "1"

  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers

  alias TymeslotWeb.Themes.Quill.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    CustomQuestionsComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper, as: QuillThemeWrapper

  # Handle month navigation (Quill has a full monthly calendar grid)
  defp handle_theme_schedule_event(socket, event, _data)
       when event in [:prev_month, :next_month] do
    direction = if event == :prev_month, do: :prev, else: :next
    {:noreply, handle_month_navigation(socket, direction)}
  end

  defp handle_theme_schedule_event(socket, _event, _data), do: {:noreply, socket}

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

    socket
    |> assign(:current_year, year)
    |> assign(:current_month, month)
    |> assign(:selected_date, nil)
    |> assign(:selected_time, nil)
    |> assign(:available_slots, [])
    |> assign(:month_availability_map, nil)
    |> assign(:availability_status, :not_loaded)
    |> AvailabilityHelpers.fetch_month_availability_async()
  end

  @impl Phoenix.LiveView
  def render(assigns) do
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
          <% :questions -> %>
            <.live_component module={CustomQuestionsComponent} id="questions-step" {assigns} />
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
