defmodule TymeslotWeb.Themes.Rhythm.Payment.Page do
  @moduledoc """
  The frame of Rhythm's two payment return pages: the booking page's own
  wrapper (`Wrapper.rhythm_wrapper/1`, so its video or still background,
  palette, language switcher and extensions) around the box its confirmation
  step uses, marked with the confirmation's badge while the booking waits or
  once it is confirmed.

  The pages render it as a function, not as a component, from assigns the
  shared return LiveViews set, so the optional ones are read with
  `assigns[...]`.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper

  attr :theme_tokens, :any, default: nil
  attr :locale, :string, default: nil
  attr :language_dropdown_open, :boolean, default: false
  attr :testid, :string, required: true
  attr :status, :atom, default: nil, values: [nil, :waiting, :confirmed, :ended]
  slot :inner_block, required: true

  @doc "A payment return page's body inside Rhythm's booking page shell."
  @spec page(map()) :: Phoenix.LiveView.Rendered.t()
  def page(assigns) do
    ~H"""
    <Wrapper.rhythm_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={true}
    >
      <div class="scheduling-box booker-card" data-testid={@testid}>
        <div class="payment-page-card-body">
          <.badge :if={@status in [:waiting, :confirmed]} status={@status} />
          {render_slot(@inner_block)}
        </div>
      </div>
    </Wrapper.rhythm_wrapper>
    """
  end

  attr :status, :atom, required: true

  # The confirmation step's badge: a tick once confirmed, a clock in the
  # held colours while the booking waits.
  defp badge(assigns) do
    ~H"""
    <div class="payment-page-badge success-badge">
      <div class={["success-badge-inner", @status == :waiting && "success-badge-inner--pending"]}>
        <svg
          class="success-icon"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
          aria-hidden="true"
        >
          <path
            :if={@status == :confirmed}
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="3"
            d="M5 13l4 4L19 7"
          />
          <path
            :if={@status == :waiting}
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="3"
            d="M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z"
          />
        </svg>
      </div>
    </div>
    """
  end
end
