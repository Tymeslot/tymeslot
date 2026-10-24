defmodule TymeslotWeb.Themes.Quill.Payment.Page do
  @moduledoc """
  The frame of Quill's two payment return pages: the booking page's own
  wrapper (`Wrapper.quill_wrapper/1`, so its background, palette, language
  switcher and extensions) around a glass card like the confirmation step's,
  marked with the confirmation's badge while the booking waits or once it is
  confirmed.

  The pages render it as a function, not as a component, from assigns the
  shared return LiveViews set, so the optional ones are read with
  `assigns[...]`.
  """
  use Phoenix.Component

  use TymeslotWeb.Components.CoreComponents, only: [glass_morphism_card: 1]

  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper

  attr :theme_tokens, :any, default: nil
  attr :locale, :string, default: nil
  attr :language_dropdown_open, :boolean, default: false
  attr :testid, :string, required: true
  attr :status, :atom, default: nil, values: [nil, :waiting, :confirmed, :ended]
  slot :inner_block, required: true

  @doc "A payment return page's body inside Quill's booking page shell."
  @spec page(map()) :: Phoenix.LiveView.Rendered.t()
  def page(assigns) do
    ~H"""
    <Wrapper.quill_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={true}
    >
      <div class="quill-container payment-page-layout" data-testid={@testid}>
        <div class="payment-page-inner">
          <.glass_morphism_card class="booker-card">
            <div class="payment-page-card-body">
              <.badge :if={@status in [:waiting, :confirmed]} status={@status} />
              {render_slot(@inner_block)}
            </div>
          </.glass_morphism_card>
        </div>
      </div>
    </Wrapper.quill_wrapper>
    """
  end

  attr :status, :atom, required: true

  # The confirmation step's badge: a tick once confirmed, a clock in the
  # pending colours while the booking waits.
  defp badge(assigns) do
    ~H"""
    <div class={[
      "payment-page-badge confirmation-badge rounded-full flex items-center justify-center",
      @status == :waiting && "confirmation-badge--pending"
    ]}>
      <svg
        class="confirmation-badge-icon text-white"
        fill="none"
        stroke="currentColor"
        stroke-width="3"
        viewBox="0 0 24 24"
        aria-hidden="true"
      >
        <path
          :if={@status == :confirmed}
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M5 13l4 4L19 7"
        />
        <path
          :if={@status == :waiting}
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z"
        />
      </svg>
    </div>
    """
  end
end
