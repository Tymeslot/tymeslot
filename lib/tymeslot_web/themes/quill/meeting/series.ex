defmodule TymeslotWeb.Themes.Quill.Meeting.Series do
  @moduledoc """
  Quill's series page: the shared body (`Shared.Components.SeriesPage`) in
  Quill's wrapper and glass card.
  """
  use Phoenix.Component

  use TymeslotWeb.Components.CoreComponents, only: [glass_morphism_card: 1]

  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper
  alias TymeslotWeb.Themes.Shared.Components.SeriesPage

  @doc "Renders the series page in Quill's look."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.quill_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      offered_locales={assigns[:offered_locales]}
      legal_links={@legal_links}
      show_language_switcher={true}
    >
      <div class="min-h-screen flex items-center justify-center px-4 py-8">
        <div class="w-full max-w-2xl">
          <.glass_morphism_card class="booker-card">
            <div class="p-8 manage-page manage-page--series" data-testid="quill-series">
              <SeriesPage.from_page {assigns} />
            </div>
          </.glass_morphism_card>
        </div>
      </div>
    </Wrapper.quill_wrapper>
    """
  end
end
