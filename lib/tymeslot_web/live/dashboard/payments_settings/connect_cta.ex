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
      <%!--
        Opening Stripe takes a moment (two Stripe API calls before the
        redirect). `data-submit-loading` lets the global submit handler show a
        spinner and disable the button so a slow redirect cannot be rage-clicked.
      --%>
      <form action={~p"/dashboard/payments/connect"} method="post" data-submit-loading>
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <.action_button type="submit" variant={:primary}>
          <span data-submit-spinner class="hidden items-center gap-2">
            <.spinner /> Connecting…
          </span>
          <span data-submit-label>Connect Stripe</span>
        </.action_button>
      </form>
    </.detail_card>
    """
  end
end
