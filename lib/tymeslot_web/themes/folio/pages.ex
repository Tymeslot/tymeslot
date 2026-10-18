defmodule TymeslotWeb.Themes.Folio.Pages do
  @moduledoc """
  Folio's page shell (`page_shell:`): its wrapper around each default page
  body (`Shared.DefaultPages`): the meeting and poll pages in one card with
  a slim cover band at its top, the payment pages, which follow a booking on
  the card-less page, with the band edge to edge and the body in the reading
  column. The masthead carries the organiser's portrait and name below the
  band when the page has their profile, and the band alone when it does
  not (a payment page's dead render, before the profile is read).
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Folio.Components.Masthead
  alias TymeslotWeb.Themes.Folio.Scheduling.Wrapper

  # The payment pages follow a booking made on Folio's card-less page, so
  # they are drawn without a card too; the meeting and poll pages keep it.
  @plain_pages [:payment_processing, :payment_cancelled]

  attr :page, :atom, required: true
  attr :theme_tokens, :any, default: nil
  attr :organizer_profile, :map, default: nil
  attr :locale, :string, default: nil
  attr :language_dropdown_open, :boolean, default: nil
  slot :inner_block, required: true

  @spec page_shell(map()) :: Phoenix.LiveView.Rendered.t()
  def page_shell(assigns) do
    assigns = assign(assigns, :plain, assigns.page in @plain_pages)

    ~H"""
    <Wrapper.folio_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={@locale != nil}
    >
      <section
        class={[
          if(@plain, do: "folio-plain-page", else: "folio-card folio-card--page"),
          "booker-card"
        ]}
        data-page={@page}
      >
        <Masthead.masthead
          variant={:slim}
          theme_tokens={@theme_tokens}
          organizer_profile={@organizer_profile}
        />
        <div class={if @plain, do: "folio-section folio-plain-page__body", else: "folio-card__body"}>
          {render_slot(@inner_block)}
        </div>
      </section>
    </Wrapper.folio_wrapper>
    """
  end
end
