defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.PaymentsSection do
  @moduledoc """
  Stateless function component for the meeting-type form's Payments section.

  Renders the "require payment" toggle and the price input. Gating is
  decided by the parent `MeetingTypeForm` (feature flag + Stripe charges
  enabled); this component only reflects the `charges_enabled` flag it is
  given — disabling the toggle and showing a connect-Stripe hint when the
  host cannot yet accept charges.

  The toggle and price input dispatch `toggle_payment_required` and
  `change_payment_price` events back to the parent form component
  (`@myself`), which owns the socket state.
  """

  use TymeslotWeb, :html

  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  import TymeslotWeb.Components.PaymentHelpers, only: [currency_symbol: 1]

  attr :charges_enabled, :boolean, required: true
  attr :payment_required, :boolean, required: true
  attr :payment_price, :string, required: true
  attr :currency, :string, required: true
  attr :currency_minimum_cents, :integer, required: true
  attr :form_errors, :map, required: true
  attr :myself, :any, required: true

  @spec payments_section(map()) :: Phoenix.LiveView.Rendered.t()
  def payments_section(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center gap-2">
        <.icon name="hero-banknotes" class="w-5 h-5 text-turquoise-500" />
        <h3 class="text-token-base font-semibold text-tymeslot-700">Payments</h3>
      </div>

      <.info_box :if={not @charges_enabled} variant={:info}>
        Connect Stripe on the
        <.link navigate={~p"/dashboard/payments"} class="underline text-turquoise-600">
          Payments
        </.link>
        page to charge for this meeting type.
      </.info_box>

      <label class={[
        "flex items-center gap-3",
        not @charges_enabled && "opacity-60 cursor-not-allowed"
      ]}>
        <input
          type="checkbox"
          class="checkbox"
          checked={@payment_required}
          disabled={not @charges_enabled}
          phx-click="toggle_payment_required"
          phx-target={@myself}
        />
        <span class="text-token-sm text-tymeslot-700">
          Require payment for this meeting type
        </span>
      </label>

      <div :if={@charges_enabled and @payment_required} class="max-w-xs">
        <.input
          type="number"
          name="meeting_type[price_input]"
          label={"Price (#{String.upcase(@currency)})"}
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
              {currency_symbol(@currency)}
            </span>
          </:leading_icon>
        </.input>
        <p class="mt-1 text-token-sm text-tymeslot-600">
          Minimum {format_minimum(@currency_minimum_cents, @currency)}.
        </p>
      </div>

      <%= for error <- FormValidationHelpers.field_errors(@form_errors, :payment_required) do %>
        <p class="form-error">{Helpers.format_errors(error)}</p>
      <% end %>
    </div>
    """
  end

  defp format_minimum(cents, currency) do
    "#{String.upcase(currency)} #{:erlang.float_to_binary(cents / 100, decimals: 2)}"
  end
end
