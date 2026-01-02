defmodule TymeslotWeb.Themes.Shared.Customization.Helpers do
  @moduledoc """
  Helper functions for applying theme customizations to booking pages.
  """
  use Phoenix.Component

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.Demo.Resolver
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Defaults
  alias TymeslotWeb.Themes.Shared.Customization.Capability

  @doc """
  Assigns theme customization data to a socket for a specific theme.
  Uses capability-based customization when available.
  """
  @spec assign_theme_customization(Phoenix.LiveView.Socket.t(), map(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def assign_theme_customization(socket, profile, theme_id) do
    customization = Resolver.get_theme_customization(profile.id, theme_id)

    # Use a fallback customization when none exists so previews always have sensible defaults
    effective_customization =
      case customization do
        nil -> Defaults.get_fallback_customization(theme_id)
        %{} = c -> c
      end

    # Generate CSS (capability-based + legacy) for the effective customization
    custom_css = ThemeCustomizations.generate_theme_css(theme_id, effective_customization)

    socket
    |> assign(:has_custom_theme, customization != nil)
    |> assign(:theme_customization, effective_customization)
    |> assign(:custom_css, custom_css)
    |> assign(:customization_options, Capability.get_customization_options(theme_id))
  end

  @doc """
  Generates custom CSS for theme customizations.
  """
  @spec generate_custom_css(ThemeCustomizationSchema.t() | nil) :: String.t()
  def generate_custom_css(nil), do: ""

  def generate_custom_css(%ThemeCustomizationSchema{} = customization) do
    [
      generate_color_scheme_css(customization.color_scheme),
      generate_gradient_mappings(customization.color_scheme),
      generate_background_css(customization)
    ]
    |> Enum.filter(&(&1 != ""))
    |> Enum.join("\n")
  end

  @doc """
  Renders a style tag with custom CSS.
  """
  @spec render_custom_theme_styles(map()) :: Phoenix.LiveView.Rendered.t()
  def render_custom_theme_styles(assigns) do
    ~H"""
    <%= if @custom_css && @custom_css != "" do %>
      <style type="text/css">
        :root {
          <%= Phoenix.HTML.raw(@custom_css) %>
        }
      </style>
    <% end %>
    """
  end

  @doc """
  Gets the background style attribute for a customization.
  """
  @spec get_background_style(ThemeCustomizationSchema.t() | map() | nil) :: String.t()
  def get_background_style(nil), do: ""

  def get_background_style(%ThemeCustomizationSchema{} = customization) do
    case customization.background_type do
      "gradient" -> get_gradient_background_style(customization)
      "color" -> get_color_background_style(customization)
      "image" -> get_image_background_style(customization)
      "video" -> ""
      _ -> ""
    end
  end

  def get_background_style(%{} = customization) when is_map(customization) do
    background_type =
      Map.get(customization, "background_type") || Map.get(customization, :background_type)

    case background_type do
      "gradient" -> get_gradient_background_style_from_map(customization)
      "color" -> get_color_background_style_from_map(customization)
      "image" -> get_image_background_style_from_map(customization)
      "video" -> ""
      _ -> ""
    end
  end

  @doc """
  Renders a background video element if needed.
  """
  @spec render_background_video(map()) :: Phoenix.LiveView.Rendered.t()
  def render_background_video(assigns) do
    ~H"""
    <%= if @theme_customization && @theme_customization.background_type == "video" && @theme_customization.background_video_path do %>
      <video autoplay muted loop playsinline class="fixed inset-0 w-full h-full object-cover -z-10">
        <source src={"/uploads/#{@theme_customization.background_video_path}"} type="video/mp4" />
      </video>
    <% end %>
    """
  end

  # Private functions

  defp generate_color_scheme_css(color_scheme) do
    ThemeCustomizations.get_color_scheme_css(color_scheme) || ""
  end

  defp generate_background_css(%{background_type: "gradient"} = customization) do
    gradient_css = ThemeCustomizations.get_gradient_css(customization.background_value)

    if gradient_css do
      "--theme-background: #{gradient_css};"
    else
      ""
    end
  end

  defp generate_background_css(%{background_type: "color", background_value: color})
       when is_binary(color) do
    "--theme-background: #{color};"
  end

  defp generate_background_css(%{background_type: "image"} = customization) do
    cond do
      is_binary(customization.background_image_path) ->
        "--theme-background-image: url('/uploads/#{customization.background_image_path}');"

      customization.background_value &&
          String.starts_with?(customization.background_value, "preset:") ->
        preset = ThemeCustomizationSchema.image_presets()[customization.background_value]

        if preset do
          "--theme-background-image: url('/images/ui/backgrounds/#{preset.file}');"
        else
          ""
        end

      true ->
        ""
    end
  end

  defp generate_background_css(_), do: ""

  defp generate_gradient_mappings(color_scheme) do
    case ThemeCustomizationSchema.color_scheme_definitions()[color_scheme] do
      nil ->
        ""

      %{colors: %{primary: primary, primary_hover: primary_hover, secondary: secondary}} ->
        """
        --glass-gradient-primary: linear-gradient(135deg, #{primary} 0%, #{primary_hover} 100%);
        --glass-gradient-secondary: linear-gradient(135deg, #{primary_hover} 0%, #{secondary} 100%);
        --color-primary-500: #{primary};
        --color-primary-600: #{primary_hover};
        """

      _ ->
        ""
    end
  end

  defp get_gradient_background_style(customization) do
    gradient_css = ThemeCustomizations.get_gradient_css(customization.background_value)
    if gradient_css, do: "background: #{gradient_css};", else: ""
  end

  defp get_color_background_style(customization) do
    if customization.background_value do
      "background-color: #{customization.background_value};"
    else
      ""
    end
  end

  defp get_image_background_style(customization) do
    cond do
      customization.background_image_path ->
        get_uploaded_image_style(customization.background_image_path)

      customization.background_value &&
          String.starts_with?(customization.background_value, "preset:") ->
        get_preset_image_style(customization.background_value)

      true ->
        ""
    end
  end

  defp get_uploaded_image_style(image_path) do
    """
    background-image: url('/uploads/#{image_path}');
    background-size: cover;
    background-position: center;
    background-repeat: no-repeat;
    """
  end

  defp get_preset_image_style(background_value) do
    preset = ThemeCustomizationSchema.image_presets()[background_value]

    if preset do
      """
      background-image: url('/images/ui/backgrounds/#{preset.file}');
      background-size: cover;
      background-position: center;
      background-repeat: no-repeat;
      """
    else
      ""
    end
  end

  # Helper functions for handling map-based customization data
  defp get_gradient_background_style_from_map(customization) do
    background_value =
      Map.get(customization, "background_value") || Map.get(customization, :background_value)

    gradient_css = ThemeCustomizations.get_gradient_css(background_value)
    if gradient_css, do: "background: #{gradient_css};", else: ""
  end

  defp get_color_background_style_from_map(customization) do
    background_value =
      Map.get(customization, "background_value") || Map.get(customization, :background_value)

    if background_value do
      "background-color: #{background_value};"
    else
      ""
    end
  end

  defp get_image_background_style_from_map(customization) do
    background_image_path =
      Map.get(customization, "background_image_path") ||
        Map.get(customization, :background_image_path)

    background_value =
      Map.get(customization, "background_value") || Map.get(customization, :background_value)

    cond do
      background_image_path ->
        get_uploaded_image_style(background_image_path)

      background_value && String.starts_with?(background_value, "preset:") ->
        get_preset_image_style(background_value)

      true ->
        ""
    end
  end
end
