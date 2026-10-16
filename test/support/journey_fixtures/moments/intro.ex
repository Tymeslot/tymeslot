defmodule TymeslotWeb.Test.JourneyFixtures.Moments.Intro do
  @moduledoc """
  Fixture Scroll's masthead: the organiser's name and the summary bar of what
  the visitor has chosen. It collects nothing, so it is on the page from the
  start.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Shared.Blocks.SummaryBar
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section
      id={"#{@moment}-step"}
      class="booker-card"
      data-moment={@moment}
      data-moment-state={@moment_state}
    >
      <h1>{Profiles.display_name(@organizer_profile)}</h1>
      <SummaryBar.summary_bar
        journey={@journey}
        meeting_type={@meeting_type}
        selected_date={@selected_date}
        selected_time={@selected_time}
        user_timezone={@user_timezone}
      />
    </section>
    """
  end
end
