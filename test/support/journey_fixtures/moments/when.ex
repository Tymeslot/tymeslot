defmodule TymeslotWeb.Test.JourneyFixtures.Moments.When do
  @moduledoc """
  Fixture Scroll's slot moment: the month calendar for the day and the slot
  list for the time.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Themes.Shared.Blocks.MonthCalendar
  alias TymeslotWeb.Themes.Shared.Components.SlotList
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
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
      <JourneyComponents.moment_heading
        moment={@moment}
        moment_state={@moment_state}
        focus={assigns[:journey_focus]}
      >
        When suits you?
      </JourneyComponents.moment_heading>
      <MonthCalendar.month_calendar
        current_year={@current_year}
        current_month={@current_month}
        user_timezone={@user_timezone}
        first_day={@week_start}
        selected_date={@selected_date}
        availability_status={@availability_status}
        booking_window_days={assigns[:booking_window_days]}
        organizer_profile={@organizer_profile}
        month_availability_map={@month_availability_map}
        meeting_type={@meeting_type}
        target={@myself}
      />
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
    </section>
    """
  end
end
