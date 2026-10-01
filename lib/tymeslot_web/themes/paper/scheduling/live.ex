defmodule TymeslotWeb.Themes.Paper.Scheduling.Live do
  @moduledoc """
  Paper's scheduling LiveView: the shared booking flow in Paper's wrapper
  and step components. Paper has no events of its own.
  """

  alias TymeslotWeb.Themes.Paper.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    CustomQuestionsComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Paper.Scheduling.Wrapper

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.paper_wrapper/1,
    steps: %{
      overview: OverviewComponent,
      schedule: ScheduleComponent,
      questions: CustomQuestionsComponent,
      booking: BookingComponent,
      confirmation: ConfirmationComponent
    }
end
