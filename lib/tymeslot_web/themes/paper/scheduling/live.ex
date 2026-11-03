defmodule TymeslotWeb.Themes.Paper.Scheduling.Live do
  @moduledoc """
  Paper's scheduling LiveView: a journey of two screens on
  `Navigators.Paged`. The overview offers the meeting types; the schedule
  screen picks the day and the time and, below them on the same screen,
  asks the meeting type's questions and the details, once a time is picked.
  Between them, a meeting type that offers several lengths asks which one
  on a screen of its own; the navigator passes it over for every other.
  Paper has no events of its own.
  """

  alias TymeslotWeb.Themes.Paper.Scheduling.Components.{
    ConfirmationComponent,
    LengthComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Paper.Scheduling.Wrapper
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.paper_wrapper/1,
    journey: [
      navigator: Paged,
      moments: [
        {:overview, collects: [:meeting_type], component: OverviewComponent},
        {:length, collects: [:length], component: LengthComponent},
        {:schedule, collects: [:slot, :answers, :attendee], component: ScheduleComponent}
      ],
      outcomes: %{confirmation: ConfirmationComponent, awaiting_payment: :shared}
    ]
end
