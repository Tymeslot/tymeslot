defmodule TymeslotWeb.Test.JourneyFixtures.Talk.Live do
  @moduledoc """
  Fixture Talk's scheduling LiveView: a conversation on
  `Navigators.Transcript`. The opening moment chooses the meeting type of an
  organiser who offers only one (`:only`), so that visitor starts at the
  meeting type's questions, or at the day when it has none; then a factless
  "which day?" moment, the times, and the details.
  """

  alias TymeslotWeb.Test.JourneyFixtures.Moments.{Ask, Confirmation, Day, Offer, Time, You}
  alias TymeslotWeb.Test.JourneyFixtures.Wrapper
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Transcript

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.talk/1,
    journey: [
      navigator: Transcript,
      moments: [
        {:hello, collects: [:meeting_type], component: Offer, defaults: [meeting_type: :only]},
        {:ask, collects: [:answers], component: Ask},
        {:day, collects: [], component: Day},
        {:time, collects: [:slot], component: Time},
        {:you, collects: [:attendee], component: You}
      ],
      outcomes: %{confirmation: Confirmation, awaiting_payment: :shared}
    ]
end
