defmodule TymeslotWeb.Themes.Quill.Payment.Page do
  @moduledoc """
  The frame of Quill's two payment return pages: the booking page's own
  wrapper (`Wrapper.quill_wrapper/1`, so its background, palette and language
  switcher) around a glass card like the confirmation step's,
  marked with the confirmation's badge while the booking waits or once it is
  confirmed.

  The theme extensions (branding banner, analytics beacon) are left out: a
  return page is not a booking-page impression.

  The pages render it as a function, not as a component, from assigns the
  shared return LiveViews set, so the optional ones are read with
  `assigns[...]`.
  """
  use Phoenix.Component

  use TymeslotWeb.Components.CoreComponents, only: [glass_morphism_card: 1, icon: 1]

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
      show_extensions={false}
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
      <.icon
        :if={@status == :confirmed}
        name="hero-check"
        class="confirmation-badge-icon text-white stroke-3"
      />
      <.icon
        :if={@status == :waiting}
        name="hero-clock"
        class="confirmation-badge-icon text-white stroke-3"
      />
    </div>
    """
  end
end
