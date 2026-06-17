defmodule Tymeslot.ThemeCustomizations.FileLifecycle do
  @moduledoc """
  Side-effecting cleanup of theme background assets on the filesystem.

  Orchestrates `Storage` and `Transcoder` to delete stale background images,
  videos, and their transcoded variants when a customisation is updated,
  deleted, or has its background replaced. Persistence is handled by the
  caller — this module only deals with files.
  """

  require Logger

  alias Tymeslot.Media.Transcoder
  alias Tymeslot.ThemeCustomizations.Storage
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @type cleanup_entry :: %{
          optional(:background_image_path) => String.t() | nil,
          optional(:background_video_path) => String.t() | nil
        }

  @doc """
  Cleans up old background files that were replaced by an update.

  Compares the customisation's previous image/video paths against the new
  values supplied in `attrs`; only paths that actually changed are deleted.
  Replaced videos also have their transcoded variants removed.
  """
  @spec cleanup_replaced_files(ThemeCustomizationSchema.t(), map()) :: :ok
  def cleanup_replaced_files(%ThemeCustomizationSchema{} = customization, attrs) do
    old_image_path = customization.background_image_path
    old_video_path = customization.background_video_path
    new_image_path = Map.get(attrs, "background_image_path")
    new_video_path = Map.get(attrs, "background_video_path")

    context = %{
      profile_id: customization.profile_id,
      theme_id: customization.theme_id,
      operation: "theme_update"
    }

    if old_image_path && old_image_path != new_image_path do
      delete_file(old_image_path, context, "old_image")
    end

    if old_video_path && old_video_path != new_video_path do
      delete_file(old_video_path, context, "old_video")
      delete_video_variants(old_video_path, context, "old_video_variant")
    end

    :ok
  end

  @doc """
  Cleans up all background files associated with a deleted customisation,
  including transcoded video variants.
  """
  @spec cleanup_all_files(ThemeCustomizationSchema.t()) :: :ok
  def cleanup_all_files(%ThemeCustomizationSchema{} = customization) do
    context = %{
      profile_id: customization.profile_id,
      theme_id: customization.theme_id,
      operation: "theme_delete"
    }

    if customization.background_image_path do
      delete_file(customization.background_image_path, context, "image")
    end

    if customization.background_video_path do
      delete_file(customization.background_video_path, context, "video")
      delete_video_variants(customization.background_video_path, context, "video_variant")
    end

    :ok
  end

  @doc """
  Legacy cleanup over a customisation-like map: deletes the referenced image
  and video files (no variant handling).
  """
  @spec cleanup_old_backgrounds(cleanup_entry() | ThemeCustomizationSchema.t()) :: :ok
  def cleanup_old_backgrounds(customization) do
    context = %{operation: "legacy_cleanup"}

    if image_path = Map.get(customization, :background_image_path) do
      delete_file(image_path, context, "image")
    end

    if video_path = Map.get(customization, :background_video_path) do
      delete_file(video_path, context, "video")
    end

    :ok
  end

  # --- Private helpers ----------------------------------------------------

  defp delete_file(relative_path, context, file_type) do
    relative_path
    |> Storage.build_theme_file_path()
    |> safe_delete(Map.put(context, :file_type, file_type))
  end

  # Best-effort filesystem delete: never fails the calling cleanup, a missing
  # file is treated as already-gone. Kept in the domain layer so this module
  # has no dependency on the web layer.
  @spec safe_delete(String.t(), map()) :: :ok
  defp safe_delete(absolute_path, context) do
    case File.rm(absolute_path) do
      :ok ->
        Logger.info("File deleted successfully", file_path: absolute_path, context: context)
        :ok

      {:error, :enoent} ->
        Logger.debug("File deletion skipped - file not found",
          file_path: absolute_path,
          context: context
        )

        :ok

      {:error, reason} ->
        Logger.warning("File deletion failed",
          file_path: absolute_path,
          reason: reason,
          context: context
        )

        :ok
    end
  end

  defp delete_video_variants(video_path, context, file_type) do
    video_path
    |> Transcoder.derive_variant_paths()
    |> Enum.each(&delete_file(&1, context, file_type))
  end
end
