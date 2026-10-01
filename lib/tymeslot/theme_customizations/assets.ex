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
  another group leaves the background alone. For a video the row is marked
  `pending` and the transcoding job queued, marking it `failed` if the job
  cannot be queued (one video field per theme: `VideoTranscoder` tracks one
  per row). A save that fails deletes the file it stored
  (`FileLifecycle.discard_upload/2`). Errors come back as translated,
  user-facing messages.

  The web layer calls this from inside `consume_uploaded_entries/3`, because
  the temporary upload is deleted as soon as that callback returns.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.FileLifecycle
  alias Tymeslot.ThemeCustomizations.Specs
  alias Tymeslot.ThemeCustomizations.Storage
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.Themes.Catalog
  alias Tymeslot.Workers.VideoTranscoder

  @type upload :: %{path: String.t(), filename: String.t()}
  @type result :: {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}

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

  defp attach(:image, profile_id, theme_id, {group, field}, upload) do
    with {:ok, path} <- store(:image, profile_id, theme_id, upload) do
      save(profile_id, theme_id, path, Specs.upload_changes(group, field, path))
    end
  end

  defp attach(:video, profile_id, theme_id, {group, field}, upload) do
    with :ok <- ensure_transcoder(),
         {:ok, path} <- store(:video, profile_id, theme_id, upload),
         {:ok, customization} <-
           save(
             profile_id,
             theme_id,
             path,
             group
             |> Specs.upload_changes(field, path)
             |> Map.put("video_processing", "pending")
           ) do
      queue_transcoding(customization, path)
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

        {:error,
         dgettext(
           "dashboard_appearance",
           "Could not save your theme customisation. Please try again."
         )}
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

  defp queue_transcoding(customization, video_path) do
    case VideoTranscoder.enqueue(customization.id, video_path) do
      {:ok, _job} ->
        {:ok, customization}

      {:error, _reason} ->
        # Only the status changes: the saved video stays, so the user can see
        # what failed and upload again.
        _marked =
          ThemeCustomizations.upsert_theme_customization(
            customization.profile_id,
            customization.theme_id,
            %{"video_processing" => "failed"}
          )

        {:error,
         dgettext(
           "dashboard_appearance",
           "Your video was saved but could not be queued for processing. Please upload it again."
         )}
    end
  end

  defp upload_failed, do: dgettext("dashboard_appearance", "Upload failed")

  defp option_unavailable,
    do: dgettext("dashboard_appearance", "This option is not available for this theme.")

  # Resolved the same way as the VideoTranscoder worker, so a test stub set via
  # `config :tymeslot, :transcoder` applies to both sides.
  defp transcoder, do: Application.get_env(:tymeslot, :transcoder, Tymeslot.Media.Transcoder)
end
