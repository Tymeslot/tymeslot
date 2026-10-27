defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.PaymentsSection do
  @moduledoc """
  Stateless function component for the meeting-type form's Payments section.

  Renders the "require payment" toggle and the price input. Gating is
  decided by the parent `MeetingTypeForm` (feature flag + Stripe charges
  enabled); this component only reflects the `charges_enabled` flag it is
  given — disabling the toggle and showing a connect-Stripe hint when the
  host cannot yet accept charges. A host whose Stripe account carries a
  currency outside the allowlist cannot set prices either, whether or not
  checkout still charges it (`Tymeslot.MeetingPayments.currency_support/1`),
  and is told why. A type that is already paid keeps its price in those
  states, so the stored amount is stated in words, in the account's currency,
  where the price input cannot be rendered. Payments and group bookings are mutually exclusive:
  while group bookings is enabled the toggle renders disabled with a hint.

  The toggle and price input dispatch `toggle_payment_required` and
  `change_payment_price` events back to the parent form component
  (`@myself`), which owns the socket state.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.HTML
  alias Tymeslot.MeetingPayments.Money
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  attr :charges_enabled, :boolean, required: true
  attr :group_bookings_enabled, :boolean, required: true
  attr :payment_required, :boolean, required: true
  attr :payment_price, :string, required: true
  attr :currency, :string, required: true
  attr :currency_support, :atom, default: :supported
  attr :account_currency, :string, required: true
  attr :stored_price, :string, required: true
  attr :currency_minimum_cents, :integer, required: true
  attr :form_errors, :map, required: true
  attr :myself, :any, required: true

  @spec payments_section(map()) :: Phoenix.LiveView.Rendered.t()
  def payments_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <.subsection_header
        icon="hero-banknotes"
        title={dgettext("dashboard_meeting_form", "Payments")}
      />

      <.setting_row
        id="payment-required-toggle"
        label={dgettext("dashboard_meeting_form", "Require payment for this meeting type")}
        checked={@payment_required}
        disabled={not @charges_enabled or @group_bookings_enabled}
        on_change="toggle_payment_required"
        target={@myself}
      >
        <:disabled_reason>
          <%= cond do %>
            <% @charges_enabled -> %>
              {dgettext("dashboard_meeting_form", "Turn off group bookings to require payment.")}
            <% @currency_support == :legacy -> %>
              {raw(
                dgettext(
                  "dashboard_meeting_form",
                  "Prices can no longer be set in your Stripe account's currency, %{currency}. Choose a supported currency on the %{payments_link} page to change what this meeting type charges.",
                  currency: escaped_code(@account_currency),
                  payments_link: payments_link()
                )
              )}
            <% @currency_support == :unsupported -> %>
              {raw(
                dgettext(
                  "dashboard_meeting_form",
                  "Your Stripe account's currency, %{currency}, is not supported for meeting payments. Choose a supported currency on the %{payments_link} page to charge for this meeting type.",
                  currency: escaped_code(@account_currency),
                  payments_link: payments_link()
                )
              )}
            <% true -> %>
              {raw(
                dgettext(
                  "dashboard_meeting_form",
                  "Connect Stripe on the %{payments_link} page to charge for this meeting type.",
                  payments_link: payments_link()
                )
              )}
          <% end %>
        </:disabled_reason>
      </.setting_row>

      <%!-- The price is kept while the host cannot set it, so it resumes when
            they reconnect rather than being cleared behind their back. The
            price input is hidden in that state, so without this the host has
            no way to see what is still stored. --%>
      <p
        :if={not @charges_enabled and @payment_required}
        class="text-token-sm text-tymeslot-600"
      >
        {stored_price_note(@currency_support, @stored_price)}
      </p>

      <div :if={@charges_enabled and @payment_required} class="max-w-xs">
        <.input
          type="number"
          name="meeting_type[price_input]"
          label={
            dgettext("dashboard_meeting_form", "Price (%{currency})",
              currency: String.upcase(@currency)
            )
          }
          value={@payment_price}
          min="0"
          step="0.01"
          placeholder="0.00"
          phx-change="change_payment_price"
          phx-debounce="500"
          phx-target={@myself}
          errors={
            FormValidationHelpers.field_errors(@form_errors, :price_cents)
            |> Enum.map(&Helpers.format_errors/1)
          }
        >
          <:leading_icon>
            <span class="text-tymeslot-400 font-bold text-token-sm tracking-tight whitespace-nowrap">
              {Money.symbol(@currency)}
            </span>
          </:leading_icon>
        </.input>
        <p class="mt-1 text-token-sm text-tymeslot-600">
          {dgettext("dashboard_meeting_form", "Minimum %{amount}.",
            amount: Money.format(@currency_minimum_cents, @currency)
          )}
        </p>
      </div>

      <%= for error <- FormValidationHelpers.field_errors(@form_errors, :payment_required) do %>
        <p class="form-error">{Helpers.format_errors(error)}</p>
      <% end %>
    </section>
    """
  end

  defp stored_price_note(support, amount) when support in [:legacy, :unsupported] do
    dgettext(
      "dashboard_meeting_form",
      "The current price is %{amount}. Switching to a supported currency clears it, as it clears every paid meeting type's price.",
      amount: amount
    )
  end

  defp stored_price_note(_support, amount) do
    dgettext(
      "dashboard_meeting_form",
      "The price of %{amount} is kept and applies again once Stripe is connected.",
      amount: amount
    )
  end

  # The code is spliced into markup that `raw/1` renders unescaped.
  defp escaped_code(currency) do
    currency |> String.upcase() |> HTML.html_escape() |> HTML.safe_to_string()
  end

  defp payments_link do
    ~s(<a href=") <>
      ~p"/dashboard/integrations?tab=payments" <>
      ~s(" data-phx-link="redirect" data-phx-link-state="push" class="underline text-turquoise-600">) <>
      dgettext("dashboard_meeting_form", "Payments") <> ~s(</a>)
  end
end
