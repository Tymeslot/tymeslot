defmodule TymeslotWeb.Themes.Quill.Scheduling.Live do
  @moduledoc """
  Quill theme scheduling LiveView: the shared booking flow in Quill's
  glassmorphism wrapper and step components.
  """

  alias TymeslotWeb.Themes.Quill.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    CustomQuestionsComponent,
    LengthComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.quill_wrapper/1,
    steps: %{
      overview: OverviewComponent,
      length: LengthComponent,
      schedule: ScheduleComponent,
      questions: CustomQuestionsComponent,
      booking: BookingComponent,
      confirmation: ConfirmationComponent
    }
end
