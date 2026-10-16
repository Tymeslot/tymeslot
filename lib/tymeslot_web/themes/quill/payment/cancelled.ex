defmodule TymeslotWeb.Themes.Quill.Payment.Cancelled do
  @moduledoc """
  Quill's shell for the payment-cancelled return page, around the shared
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
    <div class="quill-theme-wrapper" data-testid="quill-payment-cancelled">
      <ThemeStyle.theme_style :if={assigns[:theme_customized]} tokens={assigns[:theme_tokens]} />
      <div class="main-gradient theme-grid booker-page payment-page-layout">
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
