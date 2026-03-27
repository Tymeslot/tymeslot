defmodule Tymeslot.ThemeTestHelpers do
  @moduledoc """
  Minimal helpers for theme developers.
  """

  @doc """
  Generates theme file skeleton — returns a list of `{path, content}` tuples
  for the files a new theme would need.
  """
  @spec generate_theme_skeleton(String.t(), String.t()) :: {:ok, list(tuple())}
  def generate_theme_skeleton(theme_name, theme_description) do
    module_name = Macro.camelize(theme_name)

    files = [
      {"lib/tymeslot_web/themes/#{theme_name}_theme.ex",
       theme_module_template(module_name, theme_description)},
      {"lib/tymeslot_web/live/scheduling/themes/#{theme_name}/#{theme_name}_scheduling_live.ex",
       live_view_template(module_name)},
      {"assets/css/themes/scheduling-theme-#{theme_name}.css", css_template(theme_name)}
    ]

    {:ok, files}
  end

  defp theme_module_template(module_name, description) do
    """
    defmodule TymeslotWeb.Themes.#{module_name}Theme do
      @moduledoc "#{description}"

      @behaviour TymeslotWeb.Themes.Core.Behaviour

      # Implementation here...
    end
    """
  end

  defp live_view_template(module_name) do
    """
    defmodule TymeslotWeb.Live.Scheduling.Themes.#{module_name}.#{module_name}SchedulingLive do
      use TymeslotWeb, :live_view

      def mount(_params, _session, socket), do: {:ok, socket}
      def render(assigns), do: ~H"<div>Theme content</div>"
    end
    """
  end

  defp css_template(theme_name) do
    """
    /* #{String.capitalize(theme_name)} Theme */
    .#{theme_name}-theme { }
    """
  end
end
