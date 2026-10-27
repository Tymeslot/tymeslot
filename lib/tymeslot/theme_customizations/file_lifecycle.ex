defmodule Tymeslot.ThemeCustomizations.FileLifecycle do
  @moduledoc """
  Side-effecting cleanup of theme assets on the filesystem.

  Orchestrates `Tymeslot.Media.Uploads` and `Transcoder` to delete stale
  uploaded images, captions, videos, and the videos' transcoded variants
  when a customisation is updated, and removes an upload whose save was
  refused. A deleted account's files go with its whole directory
  (`Storage.delete_profile_directory/1`). Which fields hold stored
  files, and of which kind, comes from the customisation spec the caller
  passes (`asset_fields/0`, every option group's `asset_fields/1`), so a
  group's files are cleaned up without this module knowing the group.
  Persistence is handled by the caller; this module only deals with files.
  """

  alias Tymeslot.Media.Transcoder
  alias Tymeslot.Media.Uploads
  alias Tymeslot.ThemeCustomizations.DataTransform
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

  # Best-effort: `Uploads.delete_safely/2` keeps the delete inside the upload
  # root, reports a failure to the operator and never fails the calling
  # cleanup; a missing file counts as already gone.
  defp delete_file(relative_path, context, file_type) do
    Uploads.delete_safely(relative_path, Map.put(context, :file_type, file_type))
    :ok
  end

  defp delete_video_variants(video_path, context, file_type) do
    video_path
    |> Transcoder.derive_variant_paths()
    |> Enum.each(&delete_file(&1, context, file_type))
  end
end
