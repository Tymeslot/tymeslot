defmodule TymeslotWeb.Themes.Folio.Pages do
  @moduledoc """
  Folio's page shell (`page_shell:`): its wrapper and one card, a slim cover
  band at its top, around each default page body (`Shared.DefaultPages`),
  the meeting, poll and payment pages. The pages have no organiser profile,
  so the band carries no portrait or name.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Folio.Components.Masthead
  alias TymeslotWeb.Themes.Folio.Scheduling.Wrapper

  attr :page, :atom, required: true
  attr :theme_tokens, :any, default: nil
  attr :locale, :string, default: nil
  attr :language_dropdown_open, :boolean, default: nil
  slot :inner_block, required: true

  @spec page_shell(map()) :: Phoenix.LiveView.Rendered.t()
  def page_shell(assigns) do
    ~H"""
    <Wrapper.folio_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={@locale != nil}
    >
      <section class="folio-card folio-card--page booker-card" data-page={@page}>
        <Masthead.masthead variant={:slim} theme_tokens={@theme_tokens} />
        <div class="folio-card__body">
          {render_slot(@inner_block)}
        </div>
      </section>
    </Wrapper.folio_wrapper>
    """
  end
end
