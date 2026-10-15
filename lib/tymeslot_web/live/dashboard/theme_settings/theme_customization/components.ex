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
      />

      <div class="flex items-center justify-between gap-3 md:justify-start">
        <%= if @profile && @profile.username do %>
          <.action_link
            href={PreviewMode.owner_path(@profile.username, @profile.user_id, theme: @theme_id)}
            target="_blank"
            rel="noopener noreferrer"
            variant={:secondary}
            icon="hero-eye"
          >
            {dgettext("dashboard_appearance", "Live Preview")}
          </.action_link>
        <% end %>
        <.action_button
          variant={:outline}
          icon="hero-x-mark"
          phx-click="close_customization"
          phx-target={@parent_component}
        >
          {dgettext("dashboard_appearance", "Close")}
        </.action_button>
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
