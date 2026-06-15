defmodule TymeslotWeb.Dashboard.PaymentsSettings.ConnectCta do
  @moduledoc """
  Call-to-action shown when the host has no Stripe connect account yet.

  Stateless function component rendered by `PaymentsSettingsComponent`. Posts
  to the Stripe Connect onboarding endpoint via a plain form (not a LiveView
  event) so the controller can issue the OAuth redirect.
  """

  use TymeslotWeb, :html

  @spec connect_cta(map()) :: Phoenix.LiveView.Rendered.t()
  def connect_cta(assigns) do
    ~H"""
    <.detail_card title="Connect Stripe">
      <p class="text-tymeslot-700 mb-6">
        Connect Stripe to start charging for meetings. Money goes directly
        to your Stripe account.
      </p>
      <form id="stripe-connect-form" action={~p"/dashboard/payments/connect"} method="post">
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <.action_button type="submit" variant={:primary}>Connect Stripe</.action_button>
      </form>
    </.detail_card>
    """
  end
end
