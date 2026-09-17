defmodule Tymeslot.ThemeCustomizations.Backgrounds do
  @moduledoc """
  Pure functions for background operations and transformations.
  Handles background type changes and cleanup logic.
  """

  @type cleanup_file ::
          %{required(:background_image_path) => String.t()}
          | %{required(:background_video_path) => String.t()}

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

      _other_type ->
        customization
    end
  end

  @doc """
  Determines which files need cleanup when changing backgrounds.
  Returns a list of file paths that should be removed.
  """
  @spec determine_cleanup_files(term(), term()) :: [cleanup_file()]
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
