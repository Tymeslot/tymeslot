defmodule TymeslotWeb.Dashboard.PaymentsSettings.StatusCard do
  @moduledoc """
  Stripe Connect onboarding status banner.

  Stateless function component rendered by `PaymentsSettingsComponent`. Maps a
  connect account's display state — derived once by
  `Tymeslot.MeetingPayments.connect_display_state/1` — to a variant, title, and
  message.

  Two states are distinct on purpose:

    * `:incomplete` — the host started connecting but has not finished Stripe
      onboarding (`details_submitted: false`). There is nothing for Stripe to
      review yet, so the banner shows a "Finish connecting Stripe" prompt with
      a Continue-onboarding button that re-POSTs to `/dashboard/payments/connect`
      for a fresh Stripe AccountLink.
    * `:pending_review` — onboarding *is* submitted but charges/payouts are not
      yet enabled, i.e. Stripe is genuinely reviewing the account.

  `needs_onboarding?/1` is exposed so the parent can hide the operational
  sections (currency, payments, stats, disconnect) until onboarding is
  submitted, off the same single source of truth as the banner.
  """

  use TymeslotWeb, :html

  alias Tymeslot.MeetingPayments

  attr :account, :map, required: true

  @spec status_card(map()) :: Phoenix.LiveView.Rendered.t()
  def status_card(assigns) do
    assigns = assign(assigns, :state, MeetingPayments.connect_display_state(assigns.account))

    ~H"""
    <div class="space-y-4">
      <.info_box variant={status_variant(@state)}>
        <span class="block text-token-xl font-black tracking-tight">{state_title(@state)}</span>
        <span class="block mt-1">{state_message(@account, @state)}</span>
      </.info_box>

      <%!--
        `data-submit-loading` shows a spinner and disables the button while the
        Stripe redirect is being prepared, preventing rage-clicks on a slow open.
      --%>
      <form
        id="stripe-connect-continue-form"
        :if={@state == :incomplete}
        action={~p"/dashboard/payments/connect"}
        method="post"
        data-submit-loading
      >
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <.action_button type="submit" variant={:primary}>
          <span data-submit-spinner class="hidden items-center gap-2">
            <.spinner /> Connecting…
          </span>
          <span data-submit-label>Continue onboarding</span>
        </.action_button>
      </form>
    </div>
    """
  end

  @doc """
  True when the account has not yet completed Stripe onboarding, i.e. the
  banner shows the `:incomplete` "Finish connecting Stripe" prompt.

  The parent uses this to decide whether to render the operational sections.
  """
  @spec needs_onboarding?(map()) :: boolean()
  def needs_onboarding?(account),
    do: MeetingPayments.connect_display_state(account) == :incomplete

  # ── Display mapping (state → variant/title/message) ────────────────

  defp status_variant(:ready), do: :success
  defp status_variant(:pending_review), do: :warning
  defp status_variant(:restricted), do: :error
  defp status_variant(_state), do: :info

  defp state_title(:ready), do: "Connected and ready"
  defp state_title(:pending_review), do: "Pending Stripe review"
  defp state_title(:restricted), do: "Restricted"
  defp state_title(:deleted), do: "Disconnected"
  defp state_title(:incomplete), do: "Finish connecting Stripe"

  defp state_message(%{disabled_reason: r}, :restricted), do: "Reason: #{r}"
  defp state_message(_account, :ready), do: "Charges and payouts are enabled."

  defp state_message(_account, :pending_review),
    do: "Stripe is reviewing your account. Charges switch on automatically once approved."

  defp state_message(_account, :incomplete),
    do:
      "You started connecting Stripe but haven't finished onboarding yet. " <>
        "Continue to start accepting payments."

  defp state_message(_account, :deleted),
    do: "Your Stripe account is disconnected. Reconnect to accept payments again."
end
