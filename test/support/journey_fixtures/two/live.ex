defmodule TymeslotWeb.Test.JourneyFixtures.Two.Live do
  @moduledoc """
  Fixture Two's scheduling LiveView: a journey on `Navigators.Paged` with
  two screens. The first offers the meeting types; the second picks the day
  and the time and, on the same screen, asks the meeting type's questions,
  all at once, above the details, which open once the time is picked
  (`Runtime.enter_ready/1`); one submit sends both.
  """

  alias TymeslotWeb.Test.JourneyFixtures.Moments.{Confirmation, Offer, Pick}
  alias TymeslotWeb.Test.JourneyFixtures.Wrapper
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.two/1,
    journey: [
      navigator: Paged,
      moments: [
        {:offer, collects: [:meeting_type], component: Offer},
        {:pick, collects: [:slot, :answers, :attendee], component: Pick}
      ],
      outcomes: %{confirmation: Confirmation, awaiting_payment: :shared}
    ]
end
