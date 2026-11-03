defmodule TymeslotWeb.Themes.Shared.Components.SubmitPrice do
  @moduledoc """
  A paid meeting type's price, set beside the booking's submit, so the
  visitor sees what the checkout after it will charge before pressing it:
  `BookingText.price_label/3`, in the organiser's currency and the
  booking's locale. Nothing for a free type, one without a price, or a
  reschedule (a moved meeting is not charged again). Each theme places it
  and styles it through `class`; `data-testid="submit-price"` is what the
  suites find. The amount carries a stable id, and a theme's submit points
  `aria-describedby` at it through `describedby/4`, which asks the same
  `label/4` the amount is rendered from, so the reference never dangles.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.BookingText

  @amount_id "submit-price-amount"

  @doc """
  The price text to show, or `nil` when none is (a free type, one without a
  price, or a reschedule).
  """
  @spec label(map() | nil, String.t() | nil, String.t() | nil, boolean()) :: String.t() | nil
  def label(_meeting_type, _currency, _locale, true), do: nil

  def label(meeting_type, currency, locale, false),
    do: BookingText.price_label(meeting_type, currency, locale)

  @doc """
  The id for a submit's `aria-describedby`: that of the amount when one is
  shown, `nil` (so the attribute is omitted) when not.
  """
  @spec describedby(map() | nil, String.t() | nil, String.t() | nil, boolean()) ::
          String.t() | nil
  def describedby(meeting_type, currency, locale, rescheduling) do
    if label(meeting_type, currency, locale, rescheduling), do: @amount_id
  end

  attr :meeting_type, :any, required: true
  attr :currency, :string, default: nil, doc: "the organiser's currency (`@host_currency`)"
  attr :locale, :string, default: nil
  attr :rescheduling, :boolean, default: false
  attr :class, :any, default: nil

  @spec price(map()) :: Phoenix.LiveView.Rendered.t()
  def price(assigns) do
    assigns =
      assigns
      |> assign(:amount_id, @amount_id)
      |> assign(
        :label,
        label(assigns.meeting_type, assigns.currency, assigns.locale, assigns.rescheduling)
      )

    ~H"""
    <p :if={@label} id={@amount_id} class={["submit-price", @class]} data-testid="submit-price">
      {@label}
    </p>
    """
  end
end
