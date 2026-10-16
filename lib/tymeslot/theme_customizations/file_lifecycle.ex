defmodule Tymeslot.ThemeCustomizations.FileLifecycle do
  @moduledoc """
  Side-effecting cleanup of theme assets on the filesystem.

  Orchestrates `Storage` and `Transcoder` to delete stale uploaded images,
  captions, videos, and the videos' transcoded variants when a customisation
  is updated, deleted, or has its background replaced, and removes an upload
  whose save was refused. Which fields hold stored files, and of which kind, comes from
  the customisation spec the caller passes (`asset_fields/0`, every option
  group's `asset_fields/1`), so a group's files are cleaned up without this
  module knowing the group. Persistence is handled by the caller; this module
  only deals with files.
  """

  require Logger

  alias Tymeslot.Media.Transcoder
  alias Tymeslot.ThemeCustomizations.DataTransform
  alias Tymeslot.ThemeCustomizations.Storage
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @doc """
  Deletes the files an update replaced: every asset field of `spec` whose
  stored path changed between the record before and after the update.
  Replaced videos also lose their transcoded variants.
  """
  @spec cleanup_replaced_files(
          module(),
          ThemeCustomizationSchema.t(),
          ThemeCustomizationSchema.t()
        ) :: :ok
  def cleanup_replaced_files(
        spec,
        %ThemeCustomizationSchema{} = previous,
        %ThemeCustomizationSchema{} = updated
      ) do
    context = %{
      profile_id: previous.profile_id,
      theme_id: previous.theme_id,
      operation: "theme_update"
    }

    Enum.each(spec.asset_fields(), fn {field, kind} ->
      old_path = setting(previous, field)

      if old_path && old_path != setting(updated, field) do
        delete_asset(old_path, kind, context, "old_#{kind}")
      end
    end)
  end

  @doc """
  Deletes every stored file of a deleted customisation, including transcoded
  video variants.
  """
  @spec cleanup_all_files(module(), ThemeCustomizationSchema.t()) :: :ok
  def cleanup_all_files(spec, %ThemeCustomizationSchema{} = customization) do
    context = %{
      profile_id: customization.profile_id,
      theme_id: customization.theme_id,
      operation: "theme_delete"
    }

    Enum.each(spec.asset_fields(), fn {field, kind} ->
      if path = setting(customization, field), do: delete_asset(path, kind, context, "#{kind}")
    end)
  end

  @doc """
  Deletes the file an upload has just stored, when saving it was refused.

  Only that file: its name is the upload's own (`Storage.store_asset/4`), so
  nothing else can reference it, and a video has no transcoded variants yet
  because transcoding is queued only after a successful save. Never widen this
  to "every file the row does not reference": another tab may have just stored
  a file of its own in the same directory.
  """
  @spec discard_upload(String.t(), map()) :: :ok
  def discard_upload(relative_path, context),
    do:
      delete_file(
        relative_path,
        Map.put(context, :operation, "upload_rejected"),
        "rejected_upload"
      )

  # --- Private helpers ----------------------------------------------------

  defp setting(customization, field),
    do: Map.get(DataTransform.to_settings(customization), Atom.to_string(field))

  defp delete_asset(path, kind, context, label) when kind in [:image, :captions],
    do: delete_file(path, context, label)

  defp delete_asset(path, :video, context, label) do
    delete_file(path, context, label)
    delete_video_variants(path, context, label <> "_variant")
  end

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
