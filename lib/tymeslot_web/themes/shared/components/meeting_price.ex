defmodule TymeslotWeb.Themes.Shared.Components.MeetingPrice do
  @moduledoc """
  Tells a booking visitor what a paid meeting type costs, and a booker who
  has paid what they paid.

    * `hint/1`: beside a paid type in the overview list and in the heading
      of the steps that follow, the price in the organiser's currency.
    * `paid_price/2`: the amount a booking's payment took, written for the
      guest's locale, for the confirmation an embedded paid booking reaches
      once the payment webhook lands.

  `hint/1` renders nothing for a free meeting type (or an unknown
  currency), so free pages keep their markup untouched. The markup is
  theme-neutral, styled through each theme's tokens by the pill it shares
  with `GroupSession.hint/1`, in
  `assets/css/scheduling/shared/components/group-session.css`.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias TymeslotWeb.Components.PaymentHelpers
  alias TymeslotWeb.Themes.Shared.BookingText

  attr :meeting_type, :any, required: true
  attr :currency, :string, default: nil
  attr :locale, :string, required: true
  attr :class, :string, default: nil

  @doc "The compact price marker for a paid meeting type."
  @spec hint(map()) :: Phoenix.LiveView.Rendered.t()
  def hint(assigns) do
    assigns =
      assign(
        assigns,
        :price,
        BookingText.price_label(assigns.meeting_type, assigns.currency, assigns.locale)
      )

    ~H"""
    <span :if={@price} class={["meeting-price-hint", @class]} data-testid="meeting-price">
      <.icon name="hero-credit-card-micro" class="meeting-price-hint-icon" />
      <span class="sr-only">{dgettext("booking", "Price:")}</span>
      <span>{@price}</span>
    </span>
    """
  end

  @doc """
  The amount a booking payment took, as the guest's `locale` writes it, or
  `nil` without a payment or an amount.
  """
  @spec paid_price(map() | nil, String.t()) :: String.t() | nil
  def paid_price(%{amount_cents: cents, currency: currency}, locale)
      when is_integer(cents) and cents > 0 and is_binary(currency),
      do: PaymentHelpers.format_amount(cents, currency, locale)

  def paid_price(_payment, _locale), do: nil
end
