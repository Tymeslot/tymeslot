defmodule TymeslotWeb.Themes.Shared.Customization.Capability do
  @moduledoc """
  Capability-based theme customization system.

  This module provides customization options based on theme capabilities
  rather than hardcoded theme IDs, making the system more flexible.
  """

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Themes.Registry

  @type capability :: atom()
  @type customization_type :: :color | :background | :typography | :layout
  @type customization_option :: %{
          type: customization_type(),
          key: String.t(),
          value: any(),
          label: String.t(),
          description: String.t() | nil
        }

  @doc """
  Gets available customization options for a theme based on its capabilities.
  """
  @spec get_customization_options(String.t()) :: %{
          customization_type() => [customization_option()]
        }
  def get_customization_options(theme_id) do
    case Registry.get_theme_by_id(theme_id) do
      {:ok, theme} ->
        build_options_from_capabilities(theme.features)

      _ ->
        %{}
    end
  end

  @doc """
  Validates customization values against theme capabilities.
  """
  @spec validate_customization(String.t(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate_customization(theme_id, customization_attrs) do
    case Registry.get_theme_by_id(theme_id) do
      {:ok, theme} ->
        validate_against_capabilities(theme.features, customization_attrs)

      _ ->
        {:error, ["Invalid theme ID"]}
    end
  end

  @doc """
  Gets default customization values based on theme capabilities.
  """
  @spec get_capability_defaults(String.t()) :: map()
  def get_capability_defaults(theme_id) do
    case Registry.get_theme_by_id(theme_id) do
      {:ok, theme} ->
        build_defaults_from_capabilities(theme.features)

      _ ->
        %{}
    end
  end

  @doc """
  Checks if a theme supports a specific customization type.
  """
  @spec supports_customization?(String.t(), customization_type()) :: boolean()
  def supports_customization?(theme_id, customization_type) do
    case Registry.get_theme_by_id(theme_id) do
      {:ok, theme} ->
        check_capability_support(theme.features, customization_type)

      _ ->
        false
    end
  end

  @doc """
  Generates CSS from customizations based on theme capabilities.
  """
  @spec generate_css(String.t(), map()) :: String.t()
  def generate_css(theme_id, customizations) do
    case Registry.get_theme_by_id(theme_id) do
      {:ok, theme} ->
        generate_capability_css(theme.features, customizations)

      _ ->
        ""
    end
  end

  # Private functions

  defp build_options_from_capabilities(features) do
    options = %{}

    options =
      if features[:supports_custom_colors],
        do: Map.put(options, :color, color_options()),
        else: options

    options =
      if features[:supports_video_background] || features[:supports_image_background] ||
           features[:supports_gradient_background],
         do: Map.put(options, :background, background_options(features)),
         else: options

    options
  end

  defp color_options do
    Enum.map(ThemeCustomizationSchema.color_scheme_definitions(), fn {key, %{name: name}} ->
      %{
        type: :color,
        key: key,
        value: key,
        label: name,
        description: nil
      }
    end)
  end

  defp background_options(features) do
    options = []

    options =
      if features[:supports_gradient_background],
        do: options ++ gradient_options(),
        else: options

    options =
      if features[:supports_image_background],
        do:
          options ++
            [
              %{
                type: :background,
                key: "image",
                value: "image",
                label: "Custom Image",
                description: "Upload your own background image"
              }
            ],
        else: options

    options =
      if features[:supports_video_background],
        do:
          options ++
            [
              %{
                type: :background,
                key: "video",
                value: "video",
                label: "Video Background",
                description: "Use a video as background"
              }
            ],
        else: options

    options
  end

  defp gradient_options do
    Enum.map(ThemeCustomizationSchema.gradient_definitions(), fn {key, %{name: name}} ->
      %{
        type: :background,
        key: key,
        value: key,
        label: name,
        description: nil
      }
    end)
  end

  defp validate_against_capabilities(features, attrs) do
    errors = []

    errors = validate_color_scheme(features, attrs, errors)
    errors = validate_background_type(features, attrs, errors)

    if Enum.empty?(errors) do
      {:ok, attrs}
    else
      {:error, errors}
    end
  end

  defp validate_color_scheme(features, attrs, errors) do
    if attrs["color_scheme"] && !features[:supports_custom_colors] do
      ["Theme does not support custom colors" | errors]
    else
      errors
    end
  end

  defp validate_background_type(features, attrs, errors) do
    background_type = attrs["background_type"]

    background_support = %{
      "gradient" => {:supports_gradient_background, "gradient backgrounds"},
      "image" => {:supports_image_background, "image backgrounds"},
      "video" => {:supports_video_background, "video backgrounds"}
    }

    case Map.get(background_support, background_type) do
      {feature_key, error_msg} ->
        if features[feature_key] do
          errors
        else
          ["Theme does not support #{error_msg}" | errors]
        end

      nil ->
        errors
    end
  end

  defp build_defaults_from_capabilities(features) do
    defaults = %{
      "color_scheme" => "default"
    }

    defaults =
      cond do
        features[:supports_gradient_background] ->
          Map.merge(defaults, %{
            "background_type" => "gradient",
            "background_value" => "gradient_1"
          })

        features[:supports_image_background] ->
          Map.merge(defaults, %{
            "background_type" => "image",
            "background_value" => nil
          })

        features[:supports_video_background] ->
          Map.merge(defaults, %{
            "background_type" => "video",
            "background_value" => nil
          })

        true ->
          defaults
      end

    defaults
  end

  defp check_capability_support(features, :color), do: features[:supports_custom_colors] || false

  defp check_capability_support(features, :background) do
    features[:supports_gradient_background] ||
      features[:supports_image_background] ||
      features[:supports_video_background] ||
      false
  end

  defp check_capability_support(_features, _type), do: false

  defp generate_capability_css(features, customizations) do
    css_parts = []

    # Generate color CSS if supported
    css_parts =
      if features[:supports_custom_colors] && customizations["color_scheme"] do
        color_css = ThemeCustomizations.get_color_scheme_css(customizations["color_scheme"])
        if color_css, do: [color_css | css_parts], else: css_parts
      else
        css_parts
      end

    # Generate background CSS if supported
    css_parts =
      if check_capability_support(features, :background) do
        background_css = generate_background_css(customizations)
        if background_css, do: [background_css | css_parts], else: css_parts
      else
        css_parts
      end

    Enum.join(css_parts, "\n")
  end

  defp generate_background_css(%{"background_type" => "gradient", "background_value" => value}) do
    case ThemeCustomizations.get_gradient_css(value) do
      nil -> nil
      gradient -> "--theme-background: #{gradient};"
    end
  end

  defp generate_background_css(%{"background_type" => "color", "background_value" => value}) do
    "--theme-background: #{value};"
  end

  defp generate_background_css(_), do: nil
end
