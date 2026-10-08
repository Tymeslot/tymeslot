defmodule TymeslotWeb.Test.JourneyFixtures.Moments.Day do
  @moduledoc """
  Fixture Talk's "which day?" bubble: the next free days as chips. It collects
  nothing, so it is open whenever reached. A fact's event is taken only from
  a moment collecting the fact, so its chips send the day to the times
  moment after it (`#time-step`), which collects the slot and is on screen
  with it. Once a time is chosen it names the day instead.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Test.JourneyFixtures.Markup
  alias TymeslotWeb.Themes.Shared.Blocks.DayChips
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
    <%= if @selected_time do %>
      <p data-testid="journey-fixture-day">
        {LocalizationHelpers.format_full_date_label(@selected_date)}
      </p>
    <% else %>
      <JourneyComponents.moment_heading
        moment={@moment}
        moment_state={@moment_state}
        focus={assigns[:journey_focus]}
      >
        Which day suits you?
      </JourneyComponents.moment_heading>
      <DayChips.day_chips
        availability={@month_availability_map}
        availability_status={@availability_status}
        user_timezone={@user_timezone}
        selected_date={@selected_date}
        target="#time-step"
      />
    <% end %>
    """
  end
end
