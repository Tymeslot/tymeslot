defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemePreview do
  @moduledoc """
  UI component for rendering theme previews.
  """
  use TymeslotWeb, :html

  alias Tymeslot.Themes.Theme

  @doc """
  Renders a preview for a specific theme.
  """
  attr :theme_id, :string, required: true

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    theme = Theme.get_theme(assigns.theme_id)
    assigns = assign(assigns, :theme, theme)

    ~H"""
    <%= if @theme do %>
      <div class="w-full h-full bg-tymeslot-100 rounded-token-lg overflow-hidden">
        <img
          src={@theme.preview_image}
          alt={"#{@theme.name} Theme Preview"}
          class="w-full h-full object-cover transition-transform duration-300 hover:scale-105"
          onerror="this.style.display='none'; this.nextElementSibling.style.display='flex'"
        />
        <%!-- Fallback content when image fails to load --%>
        <div
          class="w-full h-full bg-gradient-to-br from-tymeslot-100 to-turquoise-50 flex items-center justify-center"
          style="display: none;"
        >
          <div class="text-center p-4">
            <div class="w-12 h-12 bg-turquoise-500 rounded-token-lg mx-auto mb-3 flex items-center justify-center">
              <svg class="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"
                />
              </svg>
            </div>
            <p class="text-token-sm font-semibold text-tymeslot-700">{@theme.name} Theme</p>
            <p class="text-token-xs text-tymeslot-600">{@theme.description}</p>
          </div>
        </div>
      </div>
    <% else %>
      <div class="w-full h-full bg-tymeslot-100 flex items-center justify-center rounded-token-lg">
        <div class="text-center text-tymeslot-500">
          <svg class="w-12 h-12 mx-auto mb-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="1"
              d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"
            />
          </svg>
          <div class="text-token-sm">Theme Preview</div>
        </div>
      </div>
    <% end %>
    """
  end
end
