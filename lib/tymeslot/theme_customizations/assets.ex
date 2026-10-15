defmodule Tymeslot.ThemeCustomizations.Assets do
  @moduledoc """
  Attaches an uploaded file to a theme customisation.

  Generic over the theme spec's option groups: the field must be one a group
  declares in `asset_fields/1` and takes uploads into
  (`Specs.upload_group/2`), else it is refused. The file is stored for the
  field's kind (`Storage.store_asset/4`) and the owning group's
  `upload_changes/3` is saved, kept to that group's own settings: a
  background upload becomes the custom background and drops the background's
  other upload, whose file the save then deletes, while an upload into
  another group leaves the background alone. For a video, the field's
  processing state is marked `pending` (`video_processing_status`, one entry
  per asset field) and the field's transcoding job queued, marking the field
  `failed` if the job cannot be queued. A save that fails deletes the file it stored
  (`FileLifecycle.discard_upload/2`). Errors come back as translated,
  user-facing messages, except an image refused by
  `Tymeslot.Media.ImageMetadata.strip/3` for its size
  (`{:image_too_large, oversize}`) or because the node is busy with other
  uploads (`:busy`): those keep the reason, whose message depends on the
  figures it carries and is worded by the web layer.

  The web layer calls this from inside `consume_uploaded_entries/3`, because
  the temporary upload is deleted as soon as that callback returns.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Media.ImageMetadata
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.FileLifecycle
  alias Tymeslot.ThemeCustomizations.Specs
  alias Tymeslot.ThemeCustomizations.Storage
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationQueries
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.Themes.Catalog
  alias Tymeslot.Workers.VideoTranscoder

  @type upload :: %{path: String.t(), filename: String.t()}
  @type refusal :: {:image_too_large, ImageMetadata.oversize()} | :busy
  @type result :: {:ok, ThemeCustomizationSchema.t()} | {:error, String.t() | refusal()}

  @doc """
  Stores `upload` for the theme's asset field `field` (an upload setting such as
  `:background_image_path`) and saves it on the profile's customisation.
  """
  @spec attach_asset(pos_integer(), String.t(), atom(), upload()) :: result()
  def attach_asset(profile_id, theme_id, field, upload) do
    with {:ok, spec} <- Catalog.customization_spec(theme_id),
         {:ok, group, kind} <- Specs.upload_group(spec, field) do
      attach(kind, profile_id, theme_id, {group, field}, upload)
    else
      _unavailable -> {:error, option_unavailable()}
    end
  end

  # Images and captions are served as stored; only a video is transcoded.
  defp attach(kind, profile_id, theme_id, {group, field}, upload)
       when kind in [:image, :captions] do
    with {:ok, path} <- store(kind, profile_id, theme_id, upload) do
      save(profile_id, theme_id, path, Specs.upload_changes(group, field, path))
    end
  end

  defp attach(:video, profile_id, theme_id, {group, field}, upload) do
    with :ok <- ensure_transcoder(),
         {:ok, path} <- store(:video, profile_id, theme_id, upload),
         {:ok, saved} <-
           save(profile_id, theme_id, path, Specs.upload_changes(group, field, path)),
         {:ok, customization} <- mark(saved, field, "pending") do
      queue_transcoding(customization, field, path)
    end
  end

  defp store(kind, profile_id, theme_id, upload) do
    case Storage.store_asset(kind, profile_id, theme_id, upload) do
      {:ok, path} ->
        {:ok, path}

      {:error, :invalid_image_format} ->
        {:error,
         dgettext(
           "dashboard_appearance",
           "Invalid image format. Please upload a valid image file."
         )}

      {:error, :invalid_video_format} ->
        {:error,
         dgettext(
           "dashboard_appearance",
           "Invalid video format. Please upload a valid video file."
         )}

      {:error, :invalid_captions_format} ->
        {:error,
         dgettext(
           "dashboard_appearance",
           "Invalid captions file. Please upload a WebVTT (.vtt) file."
         )}

      {:error, {:image_too_large, _oversize} = reason} ->
        {:error, reason}

      {:error, :busy} ->
        {:error, :busy}

      {:error, _reason} ->
        {:error, upload_failed()}
    end
  end

  # The file was stored for this save alone, so a refused save leaves it
  # referenced by nothing: delete it rather than orphan it.
  defp save(profile_id, theme_id, path, attrs) do
    case ThemeCustomizations.upsert_theme_customization(profile_id, theme_id, attrs) do
      {:ok, customization} ->
        {:ok, customization}

      {:error, _changeset} ->
        FileLifecycle.discard_upload(path, %{profile_id: profile_id, theme_id: theme_id})
        {:error, save_failed()}
    end
  end

  # ffmpeg is detected at transcode time in the worker; without this check the
  # upload would report success and then fail silently in the background.
  defp ensure_transcoder do
    if transcoder().available?() do
      :ok
    else
      {:error,
       dgettext(
         "dashboard_appearance",
         "Video processing is unavailable on this server because ffmpeg is not installed. Install ffmpeg or use a background image instead."
       )}
    end
  end

  # Each video's state lives under its own field, so two videos of one theme
  # are processed and reported apart; the write merges into the stored map.
  defp mark(customization, field, status) do
    case ThemeCustomizationQueries.update_video_processing_status(
           customization.id,
           Atom.to_string(field),
           status
         ) do
      {:ok, updated} -> {:ok, updated}
      {:error, :not_found} -> {:error, save_failed()}
    end
  end

  defp queue_transcoding(customization, field, video_path) do
    case VideoTranscoder.enqueue(customization.id, field, video_path) do
      {:ok, _job} ->
        {:ok, customization}

      {:error, _reason} ->
        # Only the state changes: the saved video stays, so the user can see
        # what failed and upload again.
        _marked = mark(customization, field, "failed")

        {:error,
         dgettext(
           "dashboard_appearance",
           "Your video was saved but could not be queued for processing. Please upload it again."
         )}
    end
  end

  defp upload_failed, do: dgettext("dashboard_appearance", "Upload failed")

  defp save_failed,
    do:
      dgettext(
        "dashboard_appearance",
        "Could not save your theme customisation. Please try again."
      )

  defp option_unavailable,
    do: dgettext("dashboard_appearance", "This option is not available for this theme.")

  # Resolved the same way as the VideoTranscoder worker, so a test stub set via
  # `config :tymeslot, :transcoder` applies to both sides.
  defp transcoder, do: Application.get_env(:tymeslot, :transcoder, Tymeslot.Media.Transcoder)
end
