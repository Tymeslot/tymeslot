defmodule TymeslotWeb.Dashboard.PaymentsSettings.StatusCard do
  @moduledoc """
  Stripe Connect onboarding status, as the account's integration card.

  Stateless function component rendered by `PaymentsSettingsComponent`. Maps a
  connect account's display state (derived once by
  `Tymeslot.MeetingPayments.connect_display_state/1`) to a status tone, title
  and message.

  Two states are distinct on purpose:

    * `:incomplete`: the host started connecting but has not finished Stripe
      onboarding (`details_submitted: false`). There is nothing for Stripe to
      review yet, so the card shows a "Finish connecting Stripe" prompt with
      a Continue-onboarding button that re-POSTs to `/dashboard/payments/connect`
      for a fresh Stripe AccountLink.
    * `:pending_review`: onboarding *is* submitted but charges/payouts are not
      yet enabled, i.e. Stripe is genuinely reviewing the account.

  `needs_onboarding?/1` is exposed so the parent can hide the operational
  sections (currency, payments, stats, disconnect) until onboarding is
  submitted, off the same single source of truth as the card.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.IntegrationCard

  attr :account, :map, required: true

  @spec status_card(map()) :: Phoenix.LiveView.Rendered.t()
  def status_card(assigns) do
    assigns = assign(assigns, :state, MeetingPayments.connect_display_state(assigns.account))

    ~H"""
    <IntegrationCard.integration_card
      id="stripe-connect"
      title="Stripe"
      heading_level={2}
      status={{status_tone(@state), state_title(@state)}}
      pulse={@state == :pending_review}
      notice={state_message(@account, @state)}
      notice_tone={notice_tone(@state)}
    >
      <:icon><.icon name="hero-credit-card" class="w-6 h-6" /></:icon>
      <:actions :if={@state == :incomplete}>
        <%!--
          `data-submit-loading` shows a spinner and disables the button while the
          Stripe redirect is being prepared, preventing rage-clicks on a slow open.
        --%>
        <form
          id="stripe-connect-continue-form"
          action={~p"/dashboard/payments/connect"}
          method="post"
          data-submit-loading
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
          <.action_button type="submit" variant={:primary} size={:sm}>
            <span data-submit-spinner class="hidden items-center gap-2">
              <.spinner /> {dgettext("dashboard_payments", "Connecting…")}
            </span>
            <span data-submit-label>{dgettext("dashboard_payments", "Continue onboarding")}</span>
          </.action_button>
        </form>
      </:actions>
    </IntegrationCard.integration_card>
    """
  end

  @doc """
  True when the account has not yet completed Stripe onboarding, i.e. the
  card shows the `:incomplete` "Finish connecting Stripe" prompt.

  The parent uses this to decide whether to render the operational sections.
  """
  @spec needs_onboarding?(map()) :: boolean()
  def needs_onboarding?(account),
    do: MeetingPayments.connect_display_state(account) == :incomplete

  # ── Display mapping (state → tone/title/message) ───────────────────

  # Waiting on the host (`:incomplete`) or on Stripe (`:pending_review`) are
  # both amber; a closed or absent account is simply off.
  defp status_tone(:ready), do: :success
  defp status_tone(:pending_review), do: :warning
  defp status_tone(:incomplete), do: :warning
  defp status_tone(:restricted), do: :danger
  defp status_tone(_state), do: :neutral

  # The message is a sentence or two, so it goes in the card's notice, which
  # wraps; only a restriction reads as an alarm.
  defp notice_tone(:restricted), do: :danger
  defp notice_tone(_state), do: :neutral

  defp state_title(:ready), do: dgettext("dashboard_payments", "Connected and ready")
  defp state_title(:pending_review), do: dgettext("dashboard_payments", "Pending Stripe review")
  defp state_title(:restricted), do: dgettext("dashboard_payments", "Restricted")
  defp state_title(:deleted), do: dgettext("dashboard_payments", "Disconnected")
  defp state_title(:incomplete), do: dgettext("dashboard_payments", "Finish connecting Stripe")
  defp state_title(:not_connected), do: dgettext("dashboard_payments", "Not connected")

  defp state_message(%{disabled_reason: r}, :restricted),
    do: dgettext("dashboard_payments", "Reason: %{reason}", reason: r)

  defp state_message(_account, :ready),
    do: dgettext("dashboard_payments", "Charges and payouts are enabled.")

  defp state_message(_account, :pending_review),
    do:
      dgettext(
        "dashboard_payments",
        "Stripe is reviewing your account. Charges switch on automatically once approved."
      )

  defp state_message(_account, :incomplete),
    do:
      dgettext(
        "dashboard_payments",
        "You started connecting Stripe but haven't finished onboarding yet. Continue to start accepting payments."
      )

  defp state_message(_account, :deleted),
    do:
      dgettext(
        "dashboard_payments",
        "Your Stripe account is disconnected. Reconnect to accept payments again."
      )

  defp state_message(_account, :not_connected),
    do: dgettext("dashboard_payments", "Connect Stripe to start charging for meetings.")
end
