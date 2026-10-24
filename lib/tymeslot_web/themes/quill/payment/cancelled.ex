defmodule TymeslotWeb.Themes.Quill.Payment.Cancelled do
  @moduledoc """
  Quill's payment-cancelled return page: the shared
  `PaymentReturnComponents.cancelled_body/1` in the booking page's shell
  (`Quill.Payment.Page`).
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Quill.Payment.Page
  alias TymeslotWeb.Themes.Shared.PaymentReturnComponents

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Page.page
      theme_tokens={assigns[:theme_tokens]}
      locale={assigns[:locale]}
      language_dropdown_open={assigns[:language_dropdown_open]}
      testid="quill-payment-cancelled"
    >
      <PaymentReturnComponents.cancelled_body rebook_path={assigns[:rebook_path]} />
    </Page.page>
    """
  end
end
