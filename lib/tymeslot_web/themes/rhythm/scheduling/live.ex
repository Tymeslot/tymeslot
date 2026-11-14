defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Live do
  @moduledoc """
  Rhythm theme scheduling LiveView: the shared booking flow in Rhythm's
  video-background wrapper and slide components, with a series slide
  after the time for a meeting type that offers a series.
  """

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    CustomQuestionsComponent,
    LengthComponent,
    OverviewComponent,
    ScheduleComponent,
    SeriesComponent
  }

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.rhythm_wrapper/1,
    steps: %{
      overview: OverviewComponent,
      length: LengthComponent,
      schedule: ScheduleComponent,
      series: SeriesComponent,
      questions: CustomQuestionsComponent,
      booking: BookingComponent,
      confirmation: ConfirmationComponent
    }
end
