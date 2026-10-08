defmodule TymeslotWeb.Test.JourneyFixtures.Express.Live do
  @moduledoc """
  Fixture Express's scheduling LiveView: a time-first journey on
  `Navigators.Paged`. The first moment collects the meeting type and the
  slot, the type defaulted to the organiser's first; the second asks the
  meeting type's questions, when it has some, above the details.
  """

  alias TymeslotWeb.Test.JourneyFixtures.Moments.{Confirmation, Now, You}
  alias TymeslotWeb.Test.JourneyFixtures.Wrapper
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.express/1,
    journey: [
      navigator: Paged,
      moments: [
        {:now,
         collects: [:meeting_type, :slot], component: Now, defaults: [meeting_type: :first]},
        {:you, collects: [:answers, :attendee], component: You}
      ],
      outcomes: %{confirmation: Confirmation, awaiting_payment: :shared}
    ]
end
