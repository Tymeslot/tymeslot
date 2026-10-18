defmodule TymeslotWeb.Themes.Folio.Scheduling.Live do
  @moduledoc """
  Folio's scheduling LiveView: one continuous page on
  `Navigators.Continuous`. The masthead (with the summary bar of what is
  chosen), the ways to work with the organiser, the calendar once one is
  chosen, the details once a time is; each opens below the last by itself.
  The confirmation replaces everything below the masthead; the payment wait
  of an embedded paid booking replaces the whole page with the slim
  masthead above the shared wait. Folio has no events of its own.
  """

  alias TymeslotWeb.Themes.Folio.Scheduling.Components.{
    AwaitingPaymentComponent,
    ConfirmationComponent,
    MastheadMoment,
    OfferMoment,
    WhenMoment,
    YouMoment
  }

  alias TymeslotWeb.Themes.Folio.Scheduling.Wrapper
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Continuous

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.folio_wrapper/1,
    journey: [
      navigator: Continuous,
      moments: [
        {:masthead, collects: [], component: MastheadMoment},
        {:offer, collects: [:meeting_type], component: OfferMoment},
        {:when, collects: [:slot], component: WhenMoment},
        {:you, collects: [:answers, :attendee], component: YouMoment}
      ],
      outcomes: %{
        confirmation: ConfirmationComponent,
        awaiting_payment: AwaitingPaymentComponent
      }
    ]
end
