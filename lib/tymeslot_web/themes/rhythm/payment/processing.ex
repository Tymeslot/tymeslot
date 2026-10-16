defmodule TymeslotWeb.Themes.Rhythm.Payment.Processing do
  @moduledoc """
  Rhythm's shell for the payment-processing return page, around the shared
  `PaymentReturnComponents.processing_body/1`.

  The organiser's customisation is written only when they saved one, so a
  page without one keeps its own default background, which is not the
  booking page's.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.PaymentReturnComponents
  alias TymeslotWeb.Themes.Shared.ThemeStyle

  attr :loading, :boolean, required: true
  attr :payment, :any, required: true
  attr :meeting, :any, required: true
  attr :rebook_path, :string, default: nil
  attr :theme_tokens, :any, default: nil
  attr :theme_customized, :boolean, default: false

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="rhythm-theme-wrapper" data-testid="rhythm-payment-processing">
      <ThemeStyle.theme_style :if={assigns[:theme_customized]} tokens={assigns[:theme_tokens]} />
      <div class="payment-page-layout">
        <div class="payment-page-inner">
          <div class="payment-page-card">
            <div class="payment-page-card-body">
              <PaymentReturnComponents.processing_body
                loading={@loading}
                payment={@payment}
                meeting={@meeting}
                rebook_path={@rebook_path}
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
