defmodule TymeslotWeb.Themes.Rhythm.Payment.Cancelled do
  @moduledoc """
  Rhythm's shell for the payment-cancelled return page, around the shared
  `PaymentReturnComponents.cancelled_body/1`.

  The organiser's customisation is written only when they saved one, so a
  page without one keeps its own default background, which is not the
  booking page's.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.PaymentReturnComponents
  alias TymeslotWeb.Themes.Shared.ThemeStyle

  attr :rebook_path, :string, default: nil
  attr :theme_tokens, :any, default: nil
  attr :theme_customized, :boolean, default: false

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="rhythm-theme-wrapper" data-testid="rhythm-payment-cancelled">
      <ThemeStyle.theme_style :if={assigns[:theme_customized]} tokens={assigns[:theme_tokens]} />
      <div class="payment-page-layout">
        <div class="payment-page-inner">
          <div class="payment-page-card">
            <div class="payment-page-card-body">
              <PaymentReturnComponents.cancelled_body rebook_path={@rebook_path} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
