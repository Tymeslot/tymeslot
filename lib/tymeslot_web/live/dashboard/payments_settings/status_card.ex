defmodule TymeslotWeb.Dashboard.PaymentsSettings.StatusCard do
  @moduledoc """
  Stripe Connect onboarding status banner.

  Stateless function component rendered by `PaymentsSettingsComponent`. Owns
  the status state machine that maps a connect account's flags
  (`deleted_at`, `disabled_reason`, `charges_enabled`/`payouts_enabled`,
  `details_submitted`) to a variant, title, and message.

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

  attr :account, :map, required: true

  @spec status_card(map()) :: Phoenix.LiveView.Rendered.t()
  def status_card(assigns) do
    assigns = assign(assigns, :state, status_state(assigns.account))

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
  def needs_onboarding?(account), do: status_state(account) == :incomplete

  # ── Status state machine ──────────────────────────────────────────

  defp status_state(%{deleted_at: dt}) when is_struct(dt, DateTime), do: :deleted
  # Onboarding that hasn't been submitted is always :incomplete. Stripe stamps a
  # brand-new account with `requirements.past_due` simply because the flow isn't
  # finished — so `disabled_reason` must not be read until `details_submitted`,
  # otherwise an unfinished account is mislabelled :restricted (and the parent
  # then wrongly reveals the operational dashboard).
  defp status_state(%{details_submitted: true} = account), do: submitted_state(account)
  defp status_state(_account), do: :incomplete

  defp submitted_state(%{disabled_reason: reason}) when is_binary(reason), do: :restricted
  defp submitted_state(%{charges_enabled: true, payouts_enabled: true}), do: :ready
  defp submitted_state(_account), do: :pending_review

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
