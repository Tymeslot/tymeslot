defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Components do
  @moduledoc """
  The customisation panel's toolbar, and `option_panel/1`, which renders an
  option group's panel.

  Customisations are kept per theme, while the booking page renders only the
  profile's chosen one, so the toolbar says so when the theme being customised
  is not it: otherwise changes saved here, which the Live Preview (rendering
  the customised theme) does show, never reach the booking page.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @spec toolbar(map()) :: Phoenix.LiveView.Rendered.t()
  def toolbar(assigns) do
    ~H"""
    <div class="mb-10 space-y-6">
      <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-6">
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

      <.info_box
        :if={@profile && @profile.booking_theme != @theme_id}
        variant={:warning}
      >
        <span id="customising-inactive-theme">
          {dgettext(
            "dashboard_appearance",
            "You are customising %{theme}, but your booking page uses %{current}. These changes appear on your booking page once you choose %{theme} as your style.",
            theme: ThemeInfo.get_theme_name(@theme_id),
            current: ThemeInfo.get_theme_name(@profile.booking_theme)
          )}
        </span>
      </.info_box>
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
