defmodule TymeslotWeb.Themes.Rhythm.Payment.Processing do
  @moduledoc """
  Rhythm's payment-processing return page: the shared
  `PaymentReturnComponents.processing_body/1` in the booking page's shell
  (`Rhythm.Payment.Page`), badged by where the booking stands.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Rhythm.Payment.Page
  alias TymeslotWeb.Themes.Shared.PaymentReturn
  alias TymeslotWeb.Themes.Shared.PaymentReturnComponents

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :status,
        PaymentReturn.progress(
          PaymentReturn.outcome(assigns.loading, assigns.payment, assigns.meeting)
        )
      )

    ~H"""
    <Page.page
      theme_tokens={assigns[:theme_tokens]}
      locale={assigns[:locale]}
      language_dropdown_open={assigns[:language_dropdown_open]}
      testid="rhythm-payment-processing"
      status={@status}
    >
      <PaymentReturnComponents.processing_body
        loading={@loading}
        payment={@payment}
        meeting={@meeting}
        rebook_path={assigns[:rebook_path]}
      />
    </Page.page>
    """
  end
end
