defmodule TymeslotWeb.Test.JourneyFixtures.Scroll.Live do
  @moduledoc """
  Fixture Scroll's scheduling LiveView: a journey on
  `Navigators.Continuous` that asks a meeting type's questions before it
  shows the calendar. Every moment the booking has reached stays on the
  page; the next opens below by itself.
  """

  alias TymeslotWeb.Test.JourneyFixtures.Moments.{Ask, Confirmation, Intro, Offer, When, You}
  alias TymeslotWeb.Test.JourneyFixtures.Wrapper
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Continuous

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.scroll/1,
    journey: [
      navigator: Continuous,
      moments: [
        {:intro, collects: [], component: Intro},
        {:offer, collects: [:meeting_type], component: Offer},
        {:ask, collects: [:answers], component: Ask},
        {:when, collects: [:slot], component: When},
        {:you, collects: [:attendee], component: You}
      ],
      outcomes: %{confirmation: Confirmation, awaiting_payment: :shared}
    ]
end
