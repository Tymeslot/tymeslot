defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Components do
  @moduledoc """
  The customisation panel's toolbar, and `option_panel/1`, which renders an
  option group's panel.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Live.Scheduling.PreviewMode

  @spec toolbar(map()) :: Phoenix.LiveView.Rendered.t()
  def toolbar(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-6 mb-10">
      <.section_header
        icon="hero-paint-brush"
        title={dgettext("dashboard_appearance", "Customise Style")}
        class="mb-0"
      />

      <div class="flex items-center justify-between gap-3 md:justify-start">
        <%= if @profile && @profile.username do %>
          <a
            href={PreviewMode.owner_path(@profile.username, @profile.user_id, theme: @theme_id)}
            target="_blank"
            rel="noopener noreferrer"
            class="btn btn-secondary py-2.5 px-5 text-token-sm"
          >
            <svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2.5"
                d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
              />
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2.5"
                d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"
              />
            </svg>
            {dgettext("dashboard_appearance", "Live Preview")}
          </a>
        <% end %>
        <button
          phx-click="close_customization"
          phx-target={@parent_component}
          class="flex items-center gap-2 px-5 py-2.5 rounded-token-xl bg-tymeslot-50 text-tymeslot-600 font-bold hover:bg-tymeslot-100 transition-all border-2 border-transparent hover:border-tymeslot-200"
        >
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2.5"
              d="M6 18L18 6M6 6l12 12"
            />
          </svg>
          {dgettext("dashboard_appearance", "Close")}
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders one option group's panel: the module `Panels.for_group/2` chose,
  passed in as `panel`, with the rest of these assigns.
  """
  @spec option_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def option_panel(%{panel: panel} = assigns), do: panel.render(assigns)
end
