defmodule TymeslotWeb.Test.FixtureTheme.Scheduling.Live do
  @moduledoc """
  The fixture theme's scheduling LiveView. Its one event of its own,
  `theme:ping` from the overview step, marks the page as pinged: the step
  sends `phx-click="theme:ping"`, `Shared.StepEvents` forwards it, and
  `SchedulingLive` hands `"ping"` to `handle_theme_event/3`.
  """

  alias TymeslotWeb.Test.FixtureTheme.Scheduling.{
    BookingStep,
    ConfirmationStep,
    OverviewStep,
    QuestionsStep,
    ScheduleStep
  }

  alias TymeslotWeb.Test.FixtureTheme.Scheduling.Wrapper

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.fixture_wrapper/1,
    steps: %{
      overview: OverviewStep,
      schedule: ScheduleStep,
      questions: QuestionsStep,
      booking: BookingStep,
      confirmation: ConfirmationStep
    }

  defp handle_theme_event("ping", _params, socket),
    do: {:noreply, assign(socket, :fixture_pinged, true)}

  defp handle_theme_event(event, params, socket), do: super(event, params, socket)
end
