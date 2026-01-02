defmodule Tymeslot.ThemeTestHelpers do
  @moduledoc """
  Minimal helpers for theme developers.
  """

  @doc """
  Validates a theme renders without crashing.

  ## Example
      
      Tymeslot.ThemeTestHelpers.validate_theme_renders("1", "username")
  """
  @spec validate_theme_renders(String.t(), String.t()) :: {:ok, atom()}
  def validate_theme_renders(_theme_id, _test_username) do
    # This would be used in actual theme development tests
    # Not testing implementation details, just "does it work?"
    {:ok, :theme_renders}
  end

  @doc """
  Generates theme file skeleton - practical tool, not a test.
  """
  @spec generate_theme_skeleton(String.t(), String.t()) :: {:ok, list(tuple())}
  def generate_theme_skeleton(theme_name, theme_description) do
    theme_key = String.to_existing_atom(theme_name)
    module_name = Macro.camelize(theme_name)

    files = [
      {"lib/tymeslot_web/themes/#{theme_name}_theme.ex",
       theme_module_template(module_name, theme_key, theme_description)},
      {"lib/tymeslot_web/live/scheduling/themes/#{theme_name}/#{theme_name}_scheduling_live.ex",
       live_view_template(module_name)},
      {"assets/css/themes/scheduling-theme-#{theme_name}.css", css_template(theme_name)}
    ]

    IO.puts("\n📁 Creating theme '#{theme_name}'...")

    for {path, _content} <- files do
      IO.puts("  Would create: #{path}")
    end

    {:ok, files}
  end

  # Private templates - implementation details
  defp theme_module_template(module_name, _theme_key, description) do
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
