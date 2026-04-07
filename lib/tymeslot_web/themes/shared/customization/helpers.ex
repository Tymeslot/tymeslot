defmodule TymeslotWeb.Themes.Shared.Customization.Helpers do
  @moduledoc """
  Helper functions for applying theme customizations to booking pages.
  """
  use Phoenix.Component

  alias Tymeslot.Demo
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Capability
  alias Tymeslot.ThemeCustomizations.Defaults
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.ThemeCustomizations.Validation

  @doc """
  Assigns theme customization data to a socket for a specific theme.
  Uses capability-based customization when available.
  """
  @spec assign_theme_customization(Phoenix.LiveView.Socket.t(), map(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def assign_theme_customization(socket, profile, theme_id) do
    customization = Demo.get_theme_customization(profile.id, theme_id)

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
  Renders a style tag with custom CSS.
  """
  attr :custom_css, :string, required: true

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
      _other -> ""
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
      _other -> ""
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

  # Private functions

  defp get_gradient_background_style(customization) do
    gradient_css = ThemeCustomizations.get_gradient_css(customization.background_value)
    if gradient_css, do: "background: #{gradient_css};", else: ""
  end

  defp valid_color?(value) when is_binary(value) do
    # Support hex colors
    # Support simple color names (common ones)
    # Support rgb/rgba
    Regex.match?(~r/^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$/, value) or
      value in ["transparent", "white", "black", "inherit", "initial"] or
      Regex.match?(~r/^rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*(\d+(?:\.\d+)?))?\)$/, value)
  end

  defp valid_color?(_other), do: false

  defp get_color_background_style(customization) do
    if customization.background_value && valid_color?(customization.background_value) do
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
    path = sanitize_path(image_path)

    """
    background-image: url('/uploads/#{path}');
    background-size: cover;
    background-position: center;
    background-repeat: no-repeat;
    """
  end

  @doc """
  Sanitizes a file path for background assets.
  Only allows alphanumeric, dots, dashes, and underscores.
  This prevents directory traversal and other injection attacks.
  """
  @spec sanitize_path(String.t() | nil) :: String.t()
  def sanitize_path(path), do: Validation.sanitize_path(path)

  @doc """
  Safely gets the background type from a customization map or struct.
  """
  @spec get_background_type(map() | struct() | nil) :: String.t() | nil
  def get_background_type(%{background_type: bg_type}), do: bg_type
  def get_background_type(%{"background_type" => bg_type}), do: bg_type
  def get_background_type(_other), do: nil

  @doc """
  Safely gets the background video path from a customization map or struct.
  """
  @spec get_background_video_path(map() | struct() | nil) :: String.t() | nil
  def get_background_video_path(%{background_video_path: path}), do: path
  def get_background_video_path(%{"background_video_path" => path}), do: path
  def get_background_video_path(_other), do: nil

  @doc """
  Safely gets the background value from a customization map or struct.
  """
  @spec get_background_value(map() | struct() | nil) :: String.t() | nil
  def get_background_value(%{background_value: value}), do: value
  def get_background_value(%{"background_value" => value}), do: value
  def get_background_value(_other), do: nil

  @doc """
  Prepares common wrapper assigns for theme wrapper components.

  Computes and assigns `has_video_background`, `video_poster`, and
  `show_language_switcher` so each theme wrapper doesn't duplicate this logic.
  """
  @spec prepare_wrapper_assigns(map()) :: map()
  def prepare_wrapper_assigns(assigns) do
    has_video_background =
      assigns[:theme_customization] &&
        get_background_type(assigns[:theme_customization]) == "video"

    show_language_switcher =
      if is_boolean(assigns[:show_language_switcher]),
        do: assigns[:show_language_switcher],
        else: assigns[:current_state] == :overview

    assigns
    |> assign(:has_video_background, has_video_background)
    |> assign(:video_poster, get_background_video_poster(assigns[:theme_customization]))
    |> assign(:show_language_switcher, show_language_switcher)
  end

  @doc """
  Gets a poster image path for video background presets, if available.
  """
  @spec get_background_video_poster(map() | struct() | nil) :: String.t() | nil
  def get_background_video_poster(customization) do
    background_value = get_background_value(customization)

    cond do
      is_nil(background_value) ->
        nil

      background_value == "custom" ->
        nil

      String.starts_with?(background_value, "preset:") ->
        preset = ThemeCustomizationSchema.video_presets()[background_value]

        if preset && preset.poster do
          "/images/ui/posters/#{preset.poster}"
        end

      true ->
        nil
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

    if background_value && valid_color?(background_value) do
      "background-color: #{background_value};"
    else
      ""
    end
  end

  defp get_preset_image_style(background_value) do
    preset = ThemeCustomizationSchema.image_presets()[background_value]

    if preset do
      """
      background-image: url('/images/themes/backgrounds/#{preset.file}');
      background-size: cover;
      background-position: center;
      background-repeat: no-repeat;
      """
    else
      ""
    end
  end
end
