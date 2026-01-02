defmodule Tymeslot.ThemeCustomizations.DataTransform do
  @moduledoc """
  Pure functions for data transformation and manipulation.
  Handles converting between different data formats and extracting attributes.
  """

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema

  @type background_type :: :gradient | :color | :image | :video | String.t()
  @type customization_struct :: ThemeCustomizationSchema.t()
  @type customization_map :: map()
  @type save_attributes_map :: %{
          optional(String.t()) => String.t() | nil
        }
  @type customization_diff :: %{optional(String.t()) => %{from: term(), to: term()}}

  @doc """
  Extracts save attributes from a customization struct.
  Returns only the fields that should be persisted to the database.
  """
  @spec extract_save_attributes(customization_struct()) :: save_attributes_map()
  def extract_save_attributes(%ThemeCustomizationSchema{} = customization) do
    %{
      "color_scheme" => customization.color_scheme,
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

  defp apply_customization_change(acc, :background_type, value),
    do: %{acc | background_type: value}

  defp apply_customization_change(acc, :background_value, value),
    do: %{acc | background_value: value}

  defp apply_customization_change(acc, :background_image_path, value),
    do: %{acc | background_image_path: value}

  defp apply_customization_change(acc, :background_video_path, value),
    do: %{acc | background_video_path: value}

  defp apply_customization_change(acc, "color_scheme", value), do: %{acc | color_scheme: value}

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
  Builds customization from LiveView assigns.
  """
  @spec build_customization_from_assigns(map(), String.t()) :: customization_struct()
  def build_customization_from_assigns(assigns, theme_id) do
    %ThemeCustomizationSchema{
      profile_id: assigns.profile.id,
      theme_id: theme_id,
      color_scheme: assigns[:color_scheme] || "default",
      background_type: assigns[:background_type] || "gradient",
      background_value: assigns[:background_value] || "gradient_1",
      background_image_path: assigns[:background_image_path],
      background_video_path: assigns[:background_video_path]
    }
  end

  @doc """
  Converts a customization struct to a map for JSON serialization.
  """
  @spec convert_to_map(nil | customization_struct() | customization_map()) :: map()
  def convert_to_map(nil), do: %{}

  def convert_to_map(%ThemeCustomizationSchema{} = customization) do
    %{
      "color_scheme" => customization.color_scheme,
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

  @doc """
  Converts string keys to atom keys for internal processing.
  """
  @spec atomize_keys(map()) :: map()
  def atomize_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      atom_key =
        case key do
          "color_scheme" -> :color_scheme
          "background_type" -> :background_type
          "background_value" -> :background_value
          "background_image_path" -> :background_image_path
          "background_video_path" -> :background_video_path
          key when is_atom(key) -> key
          key when is_binary(key) -> String.to_existing_atom(key)
          _ -> key
        end

      Map.put(acc, atom_key, value)
    end)
  rescue
    # Return original if atom conversion fails
    ArgumentError -> map
  end

  @doc """
  Prepares upload attributes for file storage.
  """
  @spec prepare_upload_attributes(
          customization_struct() | customization_map(),
          atom(),
          String.t() | nil
        ) :: customization_struct() | customization_map()
  def prepare_upload_attributes(customization, upload_type, file_path) do
    case upload_type do
      :image ->
        merge_customization_changes(customization, %{
          background_type: "image",
          background_value: "custom",
          background_image_path: file_path,
          background_video_path: nil
        })

      :video ->
        merge_customization_changes(customization, %{
          background_type: "video",
          background_value: "custom",
          background_video_path: file_path,
          background_image_path: nil
        })

      _ ->
        customization
    end
  end

  @doc """
  Creates a diff between two customizations.
  """
  @spec create_customization_diff(
          customization_struct() | customization_map(),
          customization_struct() | customization_map()
        ) :: customization_diff()
  def create_customization_diff(old_customization, new_customization) do
    old_attrs = extract_save_attributes(old_customization)
    new_attrs = extract_save_attributes(new_customization)

    Enum.reduce(new_attrs, %{}, fn {key, new_value}, acc ->
      old_value = Map.get(old_attrs, key)

      if old_value != new_value do
        Map.put(acc, key, %{from: old_value, to: new_value})
      else
        acc
      end
    end)
  end

  @doc """
  Validates and cleans customization attributes.
  """
  @spec clean_customization_attributes(map()) :: map()
  def clean_customization_attributes(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      cleaned_value = clean_attribute_value(key, value)

      if cleaned_value != nil do
        Map.put(acc, key, cleaned_value)
      else
        acc
      end
    end)
  end

  @doc """
  Checks if customization has any background files.
  """
  @spec has_background_files?(customization_struct()) :: boolean()
  def has_background_files?(%ThemeCustomizationSchema{} = customization) do
    customization.background_image_path != nil or customization.background_video_path != nil
  end

  @spec has_background_files?(customization_map()) :: boolean()
  def has_background_files?(customization) when is_map(customization) do
    Map.get(customization, :background_image_path) != nil or
      Map.get(customization, :background_video_path) != nil
  end

  @doc """
  Gets the active background file path from customization.
  """
  @spec get_active_background_file(customization_struct()) :: String.t() | nil
  def get_active_background_file(%ThemeCustomizationSchema{} = customization) do
    case customization.background_type do
      "image" when customization.background_value == "custom" ->
        customization.background_image_path

      "video" when customization.background_value == "custom" ->
        customization.background_video_path

      _ ->
        nil
    end
  end

  # Private helper functions

  @spec clean_attribute_value(String.t() | atom(), term()) :: term() | nil
  defp clean_attribute_value(key, value)
       when key in ["color_scheme", "background_type", "background_value"] and is_binary(value) do
    trimmed = String.trim(value)
    if trimmed != "", do: trimmed, else: nil
  end

  defp clean_attribute_value(_key, value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed != "", do: trimmed, else: nil
  end

  defp clean_attribute_value(_key, value), do: value
end
