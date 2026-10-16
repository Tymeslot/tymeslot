defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Live do
  @moduledoc """
  Rhythm theme scheduling LiveView: the shared booking flow in Rhythm's
  video-background wrapper and slide components.
  """

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    CustomQuestionsComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.rhythm_wrapper/1,
    steps: %{
      overview: OverviewComponent,
      schedule: ScheduleComponent,
      questions: CustomQuestionsComponent,
      booking: BookingComponent,
      confirmation: ConfirmationComponent
    }
end
