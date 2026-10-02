defmodule TymeslotWeb.Themes.Folio.Scheduling.Live do
  @moduledoc """
  Folio's scheduling LiveView: the shared booking flow in Folio's wrapper
  and step components. Folio has no events of its own.
  """

  alias TymeslotWeb.Themes.Folio.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    CustomQuestionsComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Folio.Scheduling.Wrapper

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.folio_wrapper/1,
    steps: %{
      overview: OverviewComponent,
      schedule: ScheduleComponent,
      questions: CustomQuestionsComponent,
      booking: BookingComponent,
      confirmation: ConfirmationComponent
    }
end
