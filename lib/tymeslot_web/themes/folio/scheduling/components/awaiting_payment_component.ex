defmodule TymeslotWeb.Themes.Folio.Scheduling.Components.AwaitingPaymentComponent do
  @moduledoc """
  Folio's payment wait, the journey's `:awaiting_payment` outcome: while an
  embedded booker's Stripe Checkout is open in another tab, the slim
  masthead keeps the organiser at the top of the page, as it does on the
  payment pages (`Folio.Pages`), above the shared wait
  (`Shared.Components.AwaitingPayment`), which is drawn unchanged.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Themes.Folio.Components.Masthead
  alias TymeslotWeb.Themes.Shared.Components.AwaitingPayment

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section class="folio-plain-page booker-card" data-testid="folio-payment-wait">
      <Masthead.masthead
        variant={:slim}
        theme_tokens={@theme_tokens}
        organizer_profile={@organizer_profile}
        username_context={@username_context}
      />
      <AwaitingPayment.awaiting_payment checkout_url={assigns[:awaiting_payment_checkout_url]} />
    </section>
    """
  end
end
