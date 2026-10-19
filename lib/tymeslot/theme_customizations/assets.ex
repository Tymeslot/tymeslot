defmodule Tymeslot.ThemeCustomizations.Assets do
  @moduledoc """
  Attaches an uploaded file to a theme customisation.

  Generic over the theme spec's option groups: the field must be one a group
  declares in `asset_fields/1` and takes uploads into
  (`Specs.upload_group/2`), else it is refused. The file is stored for the
  field's kind (`Storage.store_asset/4`) and the owning group's
  `upload_changes/3` is saved, kept to that group's own settings. For a
  video, the field's processing state is marked `pending`
  (`video_processing_status`, one entry per asset field) and the field's
  transcoding job queued in the same transaction as the save
  (`ThemeCustomizations.save_customization/4`), so a video is saved only
  with its job: if the job cannot be queued, nothing changes and the
  video it would have replaced stays as it was. A save that fails or is
  rolled back deletes the file it stored (`FileLifecycle.discard_upload/2`).
  Errors come back as translated, user-facing messages, except an image
  refused by `Tymeslot.Media.ImageMetadata.strip/3` for its size
  (`{:image_too_large, oversize}`) or because the node is busy with other
  uploads (`:busy`): those keep the reason, whose message depends on the
  figures it carries and is worded by the web layer.

  The web layer calls this from inside `consume_uploaded_entries/3`, because
  the temporary upload is deleted as soon as that callback returns.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.Logging.LogFormat
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
      save(profile_id, theme_id, path, Specs.upload_changes(group, field, path), &{:ok, &1})
    end
  end

  defp attach(:video, profile_id, theme_id, {group, field}, upload) do
    with :ok <- ensure_transcoder(),
         {:ok, path} <- store(:video, profile_id, theme_id, upload) do
      save(
        profile_id,
        theme_id,
        path,
        Specs.upload_changes(group, field, path),
        &queue_transcoding(&1, field, path)
      )
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

  # The file was stored for this save alone, so a refused or rolled-back
  # save leaves it referenced by nothing: delete it rather than orphan it.
  # Only the transaction's own failures arrive here as errors
  # (`ThemeCustomizations.save_customization/4`); a database error raised
  # inside it (inserting the transcoding job is the likeliest place) is
  # reported as nothing changed, and anything else is re-raised once the
  # file is gone.
  defp save(profile_id, theme_id, path, attrs, then_fun) do
    case ThemeCustomizations.save_customization(profile_id, theme_id, attrs, then_fun) do
      {:ok, customization} ->
        {:ok, customization}

      {:error, %Changeset{}} ->
        discard(path, profile_id, theme_id)
        {:error, save_failed()}

      {:error, {:raised, error, stacktrace}} ->
        discard(path, profile_id, theme_id)
        raised(error, stacktrace, profile_id, theme_id)

      {:error, _not_queued_or_not_found} ->
        discard(path, profile_id, theme_id)
        {:error, nothing_changed()}
    end
  end

  defp raised(%error_type{} = error, _stacktrace, profile_id, theme_id)
       when error_type in [Postgrex.Error, DBConnection.ConnectionError] do
    Logger.error("Theme upload rolled back by a database error",
      profile_id: profile_id,
      theme_id: theme_id,
      reason: LogFormat.reason(error)
    )

    {:error, nothing_changed()}
  end

  defp raised(error, stacktrace, _profile_id, _theme_id), do: reraise(error, stacktrace)

  defp discard(path, profile_id, theme_id),
    do: FileLifecycle.discard_upload(path, %{profile_id: profile_id, theme_id: theme_id})

  defp nothing_changed do
    dgettext(
      "dashboard_appearance",
      "The upload failed and nothing was changed. Please try again."
    )
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

  # Runs inside the save's transaction. Each video's state lives under its
  # own field, so two videos of one theme are processed and reported apart;
  # the write merges into the stored map. A failure rolls the save back.
  defp queue_transcoding(saved, field, video_path) do
    with {:ok, marked} <-
           ThemeCustomizationQueries.update_video_processing_status(
             saved.id,
             Atom.to_string(field),
             "pending"
           ),
         {:ok, _job} <- VideoTranscoder.enqueue(saved.id, field, video_path) do
      {:ok, marked}
    else
      {:error, _reason} -> {:error, :not_queued}
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
