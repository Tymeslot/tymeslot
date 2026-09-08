defmodule Tymeslot.ThemeCustomizations.DataTransform do
  @moduledoc """
  Pure functions for data transformation and manipulation.
  Handles converting between different data formats and extracting attributes.
  """

  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @type background_type :: :gradient | :color | :image | :video | String.t()
  @type customization_struct :: ThemeCustomizationSchema.t()
  @type customization_map :: %{
          optional(:color_scheme) => String.t() | nil,
          optional(:custom_palette_seed) => String.t() | nil,
          optional(:background_type) => String.t() | nil,
          optional(:background_value) => String.t() | nil,
          optional(:background_image_path) => String.t() | nil,
          optional(:background_video_path) => String.t() | nil
        }
  @type save_attributes_map :: %{
          optional(String.t()) => String.t() | nil
        }

  @doc """
  Extracts save attributes from a customization struct.
  Returns only the fields that should be persisted to the database.
  """
  @spec extract_save_attributes(customization_struct()) :: save_attributes_map()
  def extract_save_attributes(%ThemeCustomizationSchema{} = customization) do
    %{
      "color_scheme" => customization.color_scheme,
      "custom_palette_seed" => customization.custom_palette_seed,
      "background_type" => customization.background_type,
      "background_value" => customization.background_value,
      "background_image_path" => customization.background_image_path,
      "background_video_path" => customization.background_video_path
    }
  end

  @spec extract_save_attributes(customization_map()) :: save_attributes_map()
  def extract_save_attributes(customization) when is_map(customization) do
    %{
      "color_scheme" => Map.get(customization, :color_scheme),
      "custom_palette_seed" => Map.get(customization, :custom_palette_seed),
      "background_type" => Map.get(customization, :background_type),
      "background_value" => Map.get(customization, :background_value),
      "background_image_path" => Map.get(customization, :background_image_path),
      "background_video_path" => Map.get(customization, :background_video_path)
    }
  end

  @doc """
  Merges changes into an existing customization.
  """
  @spec merge_customization_changes(customization_struct(), map()) :: customization_struct()
  def merge_customization_changes(%ThemeCustomizationSchema{} = current, changes)
      when is_map(changes) do
    Enum.reduce(changes, current, fn {key, value}, acc ->
      apply_customization_change(acc, key, value)
    end)
  end

  @spec merge_customization_changes(customization_map(), map()) :: customization_map()
  def merge_customization_changes(current, changes) when is_map(current) and is_map(changes) do
    Map.merge(current, changes)
  end

  defp apply_customization_change(acc, :color_scheme, value), do: %{acc | color_scheme: value}

  defp apply_customization_change(acc, :custom_palette_seed, value),
    do: %{acc | custom_palette_seed: value}

  defp apply_customization_change(acc, :background_type, value),
    do: %{acc | background_type: value}

  defp apply_customization_change(acc, :background_value, value),
    do: %{acc | background_value: value}

  defp apply_customization_change(acc, :background_image_path, value),
    do: %{acc | background_image_path: value}

  defp apply_customization_change(acc, :background_video_path, value),
    do: %{acc | background_video_path: value}

  defp apply_customization_change(acc, "color_scheme", value), do: %{acc | color_scheme: value}

  defp apply_customization_change(acc, "custom_palette_seed", value),
    do: %{acc | custom_palette_seed: value}

  defp apply_customization_change(acc, "background_type", value),
    do: %{acc | background_type: value}

  defp apply_customization_change(acc, "background_value", value),
    do: %{acc | background_value: value}

  defp apply_customization_change(acc, "background_image_path", value),
    do: %{acc | background_image_path: value}

  defp apply_customization_change(acc, "background_video_path", value),
    do: %{acc | background_video_path: value}

  defp apply_customization_change(acc, _key, _value), do: acc

  @doc """
  Normalizes background value based on type.
  Accepts both string ("gradient" | "color" | "image" | "video") and atom
  (:gradient | :color | :image | :video) background types.
  """
  @spec normalize_background_value(background_type(), term()) :: term()
  def normalize_background_value(type, value) do
    type
    |> normalize_background_type()
    |> normalize_value_by_type(value)
  end

  defp normalize_background_type(t) when is_atom(t), do: Atom.to_string(t)
  defp normalize_background_type(t) when is_binary(t), do: t
  defp normalize_background_type(t), do: t

  defp normalize_value_by_type("gradient", v) when is_binary(v), do: v
  defp normalize_value_by_type("color", v) when is_binary(v), do: String.downcase(v)
  defp normalize_value_by_type("image", "custom"), do: "custom"
  defp normalize_value_by_type("image", v) when is_binary(v), do: v
  defp normalize_value_by_type("video", "custom"), do: "custom"
  defp normalize_value_by_type("video", v) when is_binary(v), do: v
  defp normalize_value_by_type(_type, value), do: value

  @doc """
  Converts a customization struct to a map for JSON serialization.
  """
  @spec convert_to_map(nil | customization_struct() | customization_map()) :: map()
  def convert_to_map(nil), do: %{}

  def convert_to_map(%ThemeCustomizationSchema{} = customization) do
    %{
      "color_scheme" => customization.color_scheme,
      "custom_palette_seed" => customization.custom_palette_seed,
      "background_type" => customization.background_type,
      "background_value" => customization.background_value,
      "background_image_path" => customization.background_image_path,
      "background_video_path" => customization.background_video_path
    }
  end

  def convert_to_map(customization) when is_map(customization) do
    Enum.reduce(customization, %{}, fn {key, value}, acc ->
      string_key = to_string(key)
      Map.put(acc, string_key, value)
    end)
  end
end
