defmodule TymeslotWeb.Test.FixtureTheme.Pages do
  @moduledoc """
  The fixture theme's page shell: its wrapper and a card around each
  default page body (`Shared.DefaultPages`).
  """
  use Phoenix.Component

  alias TymeslotWeb.Test.FixtureTheme.Scheduling.Wrapper

  attr :page, :atom, required: true
  attr :theme_tokens, :any, default: nil
  attr :locale, :string, default: nil
  attr :language_dropdown_open, :boolean, default: nil
  slot :inner_block, required: true

  @spec page_shell(map()) :: Phoenix.LiveView.Rendered.t()
  def page_shell(assigns) do
    ~H"""
    <Wrapper.fixture_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={@locale != nil}
    >
      <section class="booker-card" data-testid="fixture-page-shell" data-page={@page}>
        {render_slot(@inner_block)}
      </section>
    </Wrapper.fixture_wrapper>
    """
  end
end
