defmodule TymeslotWeb.Test.FixtureTheme.Scheduling.ScheduleStep do
  @moduledoc """
  The fixture theme's schedule step: the shared week grid, the way on and the
  way back. The grid asks for its week itself (`load_week`, from its
  `phx-mounted` and `phx-connected` bindings), which a LiveView test sends by
  hand.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Live.Scheduling.CalendarHelpers
  alias TymeslotWeb.Themes.Shared.Components.WeekGrid
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section class="booker-card" data-testid="fixture-schedule">
      <WeekGrid.week_grid
        week_start={@current_week_start}
        week_slots={@week_slots}
        loading={@week_slots_loading}
        error={@week_slots_error}
        selected_date={@selected_date}
        selected_time={@selected_time}
        today={@calendar_today}
        user_timezone={@user_timezone}
        booking_window_days={assigns[:booking_window_days]}
        landing_week={CalendarHelpers.landing_week(assigns)}
        target={@myself}
      />
      <button
        type="button"
        phx-click="back_step"
        phx-target={@myself}
        data-testid="back-step"
        data-intent="back"
      >
        Back
      </button>
      <button
        type="button"
        phx-click="next_step"
        phx-target={@myself}
        data-testid="next-step"
        data-intent="continue"
        disabled={is_nil(@selected_date) or is_nil(@selected_time)}
      >
        Next
      </button>
    </section>
    """
  end
end
