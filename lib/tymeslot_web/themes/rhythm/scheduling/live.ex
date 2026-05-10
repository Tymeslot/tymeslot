defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Live do
  @moduledoc """
  Rhythm theme scheduling LiveView with 4-slide flow:
  1. Overview (duration selection)
  2. Schedule (date/time selection)
  3. Booking (contact form)
  4. Confirmation (thank you page)
  """
  use TymeslotWeb.Themes.Shared.SchedulingLive, theme_id: "2"

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper, as: RhythmThemeWrapper
  alias TymeslotWeb.Themes.Shared.Components.AwaitingPayment

  @impl Phoenix.LiveView
  def render(assigns) do
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
          <% :awaiting_payment -> %>
            <AwaitingPayment.awaiting_payment checkout_url={@awaiting_payment_checkout_url} />
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
