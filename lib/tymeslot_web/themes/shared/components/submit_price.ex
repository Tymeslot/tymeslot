defmodule TymeslotWeb.Themes.Shared.Components.SubmitPrice do
  @moduledoc """
  A paid meeting type's price, set beside the booking's submit, so the
  visitor sees what the checkout after it will charge before pressing it:
  `BookingText.price_label/3`, in the organiser's currency and the
  booking's locale. Nothing for a free type, one without a price, or a
  reschedule (a moved meeting is not charged again). A group type charges
  each seat, the booker's and each guest's, so with guests added the
  amount is the total for every seat ("€60.00 for 3 seats"), and with none
  it reads per person. Each theme places it and styles it through `class`;
  `data-testid="submit-price"` is what the suites find. The amount carries
  a stable id, and a theme's submit points `aria-describedby` at it through
  `describedby/5`, which asks the same `label/5` the amount is rendered
  from, so the reference never dangles.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.PaymentHelpers
  alias TymeslotWeb.Themes.Shared.BookingText

  @amount_id "submit-price-amount"

  @doc "The seats a booking takes: the booker's, and one for each guest they add."
  @spec seats([String.t()] | nil) :: pos_integer()
  def seats(guest_emails) when is_list(guest_emails), do: 1 + length(guest_emails)
  def seats(nil), do: 1

  @doc """
  The price text to show, or `nil` when none is (a free type, one without a
  price, or a reschedule). `seats` is what the booking takes
  (`seats/1`); a group type's price for more than one is their total.
  """
  @spec label(map() | nil, String.t() | nil, String.t() | nil, boolean(), pos_integer()) ::
          String.t() | nil
  def label(meeting_type, currency, locale, rescheduling, seats \\ 1)

  def label(_meeting_type, _currency, _locale, true, _seats), do: nil

  def label(%{max_participants: max} = meeting_type, currency, locale, false, seats)
      when is_integer(max) and max > 1 and is_integer(seats) and seats > 1 do
    case BookingText.price_label(meeting_type, currency, locale) do
      nil ->
        nil

      _per_person ->
        dngettext(
          "booking",
          "%{total} for %{count} seat",
          "%{total} for %{count} seats",
          seats,
          total: PaymentHelpers.format_amount(meeting_type.price_cents * seats, currency, locale)
        )
    end
  end

  def label(meeting_type, currency, locale, false, _seats),
    do: BookingText.price_label(meeting_type, currency, locale)

  @doc """
  The id for a submit's `aria-describedby`: that of the amount when one is
  shown, `nil` (so the attribute is omitted) when not.
  """
  @spec describedby(map() | nil, String.t() | nil, String.t() | nil, boolean(), pos_integer()) ::
          String.t() | nil
  def describedby(meeting_type, currency, locale, rescheduling, seats \\ 1) do
    if label(meeting_type, currency, locale, rescheduling, seats), do: @amount_id
  end

  attr :meeting_type, :any, required: true
  attr :currency, :string, default: nil, doc: "the organiser's currency (`@host_currency`)"
  attr :locale, :string, default: nil
  attr :rescheduling, :boolean, default: false
  attr :seats, :integer, default: 1, doc: "the seats the booking takes (`seats/1`)"
  attr :class, :any, default: nil

  @spec price(map()) :: Phoenix.LiveView.Rendered.t()
  def price(assigns) do
    assigns =
      assigns
      |> assign(:amount_id, @amount_id)
      |> assign(
        :label,
        label(
          assigns.meeting_type,
          assigns.currency,
          assigns.locale,
          assigns.rescheduling,
          assigns.seats
        )
      )

    ~H"""
    <p :if={@label} id={@amount_id} class={["submit-price", @class]} data-testid="submit-price">
      {@label}
    </p>
    """
  end
end
