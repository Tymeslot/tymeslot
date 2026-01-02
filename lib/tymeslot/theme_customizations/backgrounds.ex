defmodule Tymeslot.ThemeCustomizations.Backgrounds do
  @moduledoc """
  Pure functions for background operations and transformations.
  Handles background type changes, cleanup logic, and CSS generation.
  """

  @doc """
  Applies a background selection to a customization, updating type and value.
  """
  @spec apply_background_selection(term(), String.t(), String.t()) :: term()
  def apply_background_selection(customization, type, value) do
    clear_conflicting_backgrounds(
      %{
        customization
        | background_type: type,
          background_value: value
      },
      type
    )
  end

  @doc """
  Clears background paths that conflict with the new background type.
  """
  @spec clear_conflicting_backgrounds(term(), String.t()) :: term()
  def clear_conflicting_backgrounds(customization, new_type) do
    case new_type do
      "image" when customization.background_value != "custom" ->
        # Clear custom image path when selecting preset image
        %{customization | background_image_path: nil}

      "video" when customization.background_value != "custom" ->
        # Clear custom video path when selecting preset video
        %{customization | background_video_path: nil}

      "gradient" ->
        # Clear both image and video paths when selecting gradient
        %{customization | background_image_path: nil, background_video_path: nil}

      "color" ->
        # Clear both image and video paths when selecting color
        %{customization | background_image_path: nil, background_video_path: nil}

      _ ->
        customization
    end
  end

  @doc """
  Determines which files need cleanup when changing backgrounds.
  Returns a list of file paths that should be removed.
  """
  @spec determine_cleanup_files(term(), term()) :: list(map())
  def determine_cleanup_files(old_customization, new_customization) do
    cleanup_files = []

    # Check if image file needs cleanup
    cleanup_files =
      if should_cleanup_image?(old_customization, new_customization) do
        [%{background_image_path: old_customization.background_image_path} | cleanup_files]
      else
        cleanup_files
      end

    # Check if video file needs cleanup
    cleanup_files =
      if should_cleanup_video?(old_customization, new_customization) do
        [%{background_video_path: old_customization.background_video_path} | cleanup_files]
      else
        cleanup_files
      end

    cleanup_files
  end

  @doc """
  Generates a description of the current background configuration.
  """
  @spec generate_background_description(term(), map()) :: String.t()
  def generate_background_description(customization, presets) do
    case customization.background_type do
      "gradient" -> describe_gradient(customization, presets)
      "color" -> describe_color(customization)
      "image" -> describe_image(customization, presets)
      "video" -> describe_video(customization, presets)
      _ -> "No Background Selected"
    end
  end

  defp describe_gradient(customization, presets) do
    gradient = Map.get(presets.gradients || %{}, customization.background_value)
    "Gradient: #{(gradient && gradient.name) || "Custom"}"
  end

  defp describe_color(customization) do
    "Solid Color: #{customization.background_value || "Default"}"
  end

  defp describe_image(customization, presets) do
    cond do
      custom_image?(customization) -> "Custom Image Uploaded"
      preset_image?(customization) -> get_preset_image_name(customization, presets)
      true -> "No Image Selected"
    end
  end

  defp describe_video(customization, presets) do
    cond do
      custom_video?(customization) -> "Custom Video Uploaded"
      preset_video?(customization) -> get_preset_video_name(customization, presets)
      true -> "No Video Selected"
    end
  end

  defp custom_image?(customization) do
    customization.background_value == "custom" && customization.background_image_path
  end

  defp custom_video?(customization) do
    customization.background_value == "custom" && customization.background_video_path
  end

  defp preset_image?(customization) do
    String.starts_with?(customization.background_value || "", "preset:")
  end

  defp preset_video?(customization) do
    String.starts_with?(customization.background_value || "", "preset:")
  end

  defp get_preset_image_name(customization, presets) do
    preset = Map.get(presets.images || %{}, customization.background_value)
    "Preset: #{(preset && preset.name) || "Unknown"}"
  end

  defp get_preset_video_name(customization, presets) do
    preset = Map.get(presets.videos || %{}, customization.background_value)
    "Preset: #{(preset && preset.name) || "Unknown"}"
  end

  @doc """
  Gets CSS value for a background configuration.
  """
  @spec get_background_css(term(), map()) :: String.t() | nil
  def get_background_css(customization, presets) do
    case customization.background_type do
      "gradient" -> get_gradient_css(customization, presets)
      "color" -> customization.background_value
      "image" -> get_image_css(customization, presets)
      "video" -> get_video_css(customization, presets)
      _ -> nil
    end
  end

  defp get_gradient_css(customization, presets) do
    gradient = Map.get(presets.gradients || %{}, customization.background_value)
    gradient && gradient.value
  end

  defp get_image_css(customization, presets) do
    cond do
      custom_image?(customization) -> "/uploads/#{customization.background_image_path}"
      preset_image?(customization) -> get_preset_image_path(customization, presets)
      true -> nil
    end
  end

  defp get_video_css(customization, presets) do
    cond do
      custom_video?(customization) -> "/uploads/#{customization.background_video_path}"
      preset_video?(customization) -> get_preset_video_path(customization, presets)
      true -> nil
    end
  end

  @doc """
  Resolves a preview source for the given customization and presets.
  Returns one of:
  - {:gradient, %{css: css}}
  - {:color, %{css: css}}
  - {:image, %{url: url, kind: :custom | :preset, name: String.t() | nil}}
  - {:video, %{thumbnail_url: String.t() | nil, video_url: String.t() | nil, kind: :custom | :preset, name: String.t() | nil}}
  - {:none, %{}}
  """
  @spec resolve_preview_source(term(), map()) :: {atom(), map()}
  def resolve_preview_source(customization, presets) do
    case customization.background_type do
      "gradient" -> resolve_gradient(customization, presets)
      "color" -> resolve_color(customization)
      "image" -> resolve_image(customization, presets)
      "video" -> resolve_video(customization, presets)
      _ -> {:none, %{}}
    end
  end

  defp resolve_gradient(customization, presets) do
    case Map.get(presets.gradients || %{}, customization.background_value) do
      nil -> {:none, %{}}
      gradient -> {:gradient, %{css: gradient.value}}
    end
  end

  defp resolve_color(customization) do
    if customization.background_value,
      do: {:color, %{css: customization.background_value}},
      else: {:none, %{}}
  end

  defp resolve_image(customization, presets) do
    cond do
      custom_image?(customization) ->
        {:image,
         %{url: "/uploads/#{customization.background_image_path}", kind: :custom, name: nil}}

      preset_image?(customization) ->
        case Map.get(presets.images || %{}, customization.background_value) do
          nil ->
            {:none, %{}}

          preset ->
            {:image,
             %{url: "/images/ui/backgrounds/#{preset.file}", kind: :preset, name: preset.name}}
        end

      true ->
        {:none, %{}}
    end
  end

  defp resolve_video(customization, presets) do
    cond do
      custom_video?(customization) ->
        {:video,
         %{
           thumbnail_url: nil,
           video_url: "/uploads/#{customization.background_video_path}",
           kind: :custom,
           name: nil
         }}

      preset_video?(customization) ->
        case Map.get(presets.videos || %{}, customization.background_value) do
          nil ->
            {:none, %{}}

          preset ->
            {:video,
             %{
               thumbnail_url: "/videos/thumbnails/#{preset.thumbnail}",
               video_url: "/videos/backgrounds/#{preset.file}",
               kind: :preset,
               name: preset.name
             }}
        end

      true ->
        {:none, %{}}
    end
  end

  defp get_preset_image_path(customization, presets) do
    preset = Map.get(presets.images || %{}, customization.background_value)
    preset && "/images/ui/backgrounds/#{preset.file}"
  end

  defp get_preset_video_path(customization, presets) do
    preset = Map.get(presets.videos || %{}, customization.background_value)
    preset && "/videos/backgrounds/#{preset.file}"
  end

  @doc """
  Checks if the current background is a custom upload.
  """
  @spec custom_background?(term()) :: boolean() | binary() | nil
  def custom_background?(customization) do
    customization.background_value == "custom" &&
      (customization.background_image_path || customization.background_video_path)
  end

  @doc """
  Gets the file path for a background asset.
  """
  @spec get_background_file_path(term(), map()) :: String.t() | nil
  def get_background_file_path(customization, presets) do
    case {customization.background_type, customization.background_value} do
      {"image", "custom"} -> customization.background_image_path
      {"video", "custom"} -> customization.background_video_path
      {"image", _} -> get_image_preset_file(customization, presets)
      {"video", _} -> get_video_preset_file(customization, presets)
      _ -> nil
    end
  end

  defp get_image_preset_file(customization, presets) do
    preset = Map.get(presets.images || %{}, customization.background_value)
    preset && preset.file
  end

  defp get_video_preset_file(customization, presets) do
    preset = Map.get(presets.videos || %{}, customization.background_value)
    preset && preset.file
  end

  # Private helper functions

  defp should_cleanup_image?(old_customization, new_customization) do
    # Cleanup if we had a custom image and now we don't, or the path changed
    old_customization.background_image_path &&
      (new_customization.background_image_path != old_customization.background_image_path ||
         new_customization.background_type != "image" ||
         new_customization.background_value != "custom")
  end

  defp should_cleanup_video?(old_customization, new_customization) do
    # Cleanup if we had a custom video and now we don't, or the path changed
    old_customization.background_video_path &&
      (new_customization.background_video_path != old_customization.background_video_path ||
         new_customization.background_type != "video" ||
         new_customization.background_value != "custom")
  end
end
