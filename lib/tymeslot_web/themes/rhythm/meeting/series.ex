defmodule TymeslotWeb.Themes.Rhythm.Meeting.Series do
  @moduledoc """
  Rhythm's series page: the shared body (`Shared.Components.SeriesPage`) in
  Rhythm's wrapper and scheduling box.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper
  alias TymeslotWeb.Themes.Shared.Components.SeriesPage

  @doc "Renders the series page in Rhythm's look."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.rhythm_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      offered_locales={assigns[:offered_locales]}
      legal_links={@legal_links}
      show_language_switcher={true}
    >
      <div class="scheduling-box booker-card">
        <div class="slide-container">
          <div class="slide active">
            <div class="slide-content confirmation-slide">
              <div class="manage-page manage-page--series" data-testid="rhythm-series">
                <SeriesPage.from_page {assigns} />
              </div>
            </div>
          </div>
        </div>
      </div>
    </Wrapper.rhythm_wrapper>
    """
  end
end
