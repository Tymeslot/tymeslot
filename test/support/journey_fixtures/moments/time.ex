defmodule TymeslotWeb.Test.JourneyFixtures.Moments.Time do
  @moduledoc """
  Fixture Talk's times: the chosen day's times (the shared slot list), and
  once answered the time with an Edit control.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Test.JourneyFixtures.Markup
  alias TymeslotWeb.Themes.Shared.Components.SlotList
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns), do: Markup.moment_root(assigns, &body/1)

  defp body(assigns) do
    ~H"""
    <%= if @moment_state == :done do %>
      <p data-testid="journey-fixture-answer">
        {LocalizationHelpers.format_booking_datetime(@selected_date, @selected_time, @user_timezone)}
      </p>
      <button type="button" phx-click="navigate_to_step" phx-value-step={@moment} data-intent="edit">
        Change time
      </button>
    <% else %>
      <JourneyComponents.moment_heading
        moment={@moment}
        moment_state={@moment_state}
        focus={assigns[:journey_focus]}
      >
        Which time?
      </JourneyComponents.moment_heading>
      <SlotList.slot_list
        selected_date={@selected_date}
        selected_time={@selected_time}
        available_slots={@available_slots}
        loading_slots={@loading_slots}
        calendar_error={@calendar_error}
        slot_interval_minutes={@slot_interval_minutes}
        duration_minutes={@duration_minutes}
        expanded_hour={@expanded_hour}
        target={@myself}
      />
    <% end %>
    """
  end
end
