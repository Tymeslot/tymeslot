defmodule TymeslotWeb.Themes.Paper.Pages do
  @moduledoc """
  Paper's page shell: its wrapper and one card, with the organiser's logo
  above the body, around each default meeting, poll and payment page body
  (`Shared.DefaultPages`). The poll page takes the wide card, for its grid
  of times. The payment pages have no customisation (`theme_tokens` is nil
  there), so they show Paper's default look and no logo, and none of the
  theme extensions (branding banner, analytics beacon): a payment return
  page is not a booking-page impression.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Paper.Components
  alias TymeslotWeb.Themes.Paper.Scheduling.Wrapper

  @payment_pages [:payment_processing, :payment_cancelled]

  attr :page, :atom, required: true
  attr :theme_tokens, :any, default: nil
  attr :locale, :string, default: nil
  attr :language_dropdown_open, :boolean, default: nil
  attr :offered_locales, :list, default: nil
  attr :legal_links, :map, default: nil
  slot :inner_block, required: true

  @spec page_shell(map()) :: Phoenix.LiveView.Rendered.t()
  def page_shell(assigns) do
    assigns = assign(assigns, :payment_page, assigns.page in @payment_pages)

    ~H"""
    <Wrapper.paper_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      offered_locales={@offered_locales}
      legal_links={@legal_links}
      show_language_switcher={@locale != nil}
      show_extensions={not @payment_page}
    >
      <section
        class={["paper-card paper-card--page booker-card", @page == :poll && "paper-card--wide"]}
        data-page={@page}
      >
        <Components.brand theme_tokens={@theme_tokens} />
        {render_slot(@inner_block)}
      </section>
    </Wrapper.paper_wrapper>
    """
  end
end
