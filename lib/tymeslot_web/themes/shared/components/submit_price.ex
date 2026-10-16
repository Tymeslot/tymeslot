defmodule TymeslotWeb.Themes.Shared.Components.SubmitPrice do
  @moduledoc """
  A paid meeting type's price, set beside the booking's submit, so the
  visitor sees what the checkout after it will charge before pressing it:
  `BookingText.price_label/3`, in the organiser's currency and the
  booking's locale. Nothing for a free type, one without a price, or a
  reschedule (a moved meeting is not charged again). Each theme places it
  and styles it through `class`; `data-testid="submit-price"` is what the
  suites find.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.BookingText

  attr :meeting_type, :any, required: true
  attr :currency, :string, default: nil, doc: "the organiser's currency (`@host_currency`)"
  attr :locale, :string, default: nil
  attr :rescheduling, :boolean, default: false
  attr :class, :any, default: nil

  @spec price(map()) :: Phoenix.LiveView.Rendered.t()
  def price(assigns) do
    label =
      if assigns.rescheduling,
        do: nil,
        else: BookingText.price_label(assigns.meeting_type, assigns.currency, assigns.locale)

    assigns = assign(assigns, :label, label)

    ~H"""
    <p :if={@label} class={["submit-price", @class]} data-testid="submit-price">{@label}</p>
    """
  end
end
