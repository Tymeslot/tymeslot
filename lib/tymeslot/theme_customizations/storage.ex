defmodule Tymeslot.ThemeCustomizations.Storage do
  @moduledoc """
  Handles filesystem-related operations for theme customization assets.
  `store_asset/4` is the one way an upload is written.
  """

  alias Tymeslot.Media.ImageMetadata
  alias Tymeslot.Media.MediaValidator
  alias Tymeslot.Media.Uploads
  alias Tymeslot.Media.VideoMetadata
  alias Tymeslot.ThemeCustomizations.Spec

  @type file_upload :: %{required(:path) => Path.t(), optional(:filename) => String.t()}

  @kind_directories %{image: "images", video: "videos", captions: "captions"}

  @doc """
  Removes a profile's whole theme upload directory: every theme's images,
  videos and transcoded variants, whether or not a row still references them.
  """
  @spec delete_profile_directory(pos_integer()) :: :ok | {:error, File.posix(), Path.t()}
  def delete_profile_directory(profile_id) when is_integer(profile_id) do
    case File.rm_rf(Path.join([Uploads.root(), "themes", Integer.to_string(profile_id)])) do
      {:ok, _removed} -> :ok
      {:error, reason, failed_path} -> {:error, reason, failed_path}
    end
  end

  @doc """
  Stores an uploaded image, video or captions file for a profile's theme and
  returns its path relative to the upload root:
  `themes/<profile>/<theme>/images/<name>` for an image, `.../videos/<name>`
  for a video and `.../captions/<name>` for captions.

  The content is checked against `kind` by its bytes, never by the client's
  content type or file name. The stored name is chosen by the server
  (`Uploads.stored_name/1`), with the extension of the format the bytes are,
  which must be one the kind accepts (`Uploads.allowed_extensions/1`; an
  animated GIF is not a background); captions are always `.vtt`. No two
  uploads share a path, so a new upload never overwrites a file a setting
  still names, and deleting one upload's file never deletes another's.

  Before it is moved into the upload directory, the file the caller hands
  over at `temp_path` is cleaned in place: an image is re-encoded without its
  metadata (see `Tymeslot.Media.ImageMetadata`), and a video has its metadata
  removed (see `Tymeslot.Media.VideoMetadata`). A video that is not an MP4 or
  WebM the stripper can read to the end is refused as `:invalid_video_format`.
  Captions are plain text and carry no metadata.
  """
  @spec store_asset(Spec.asset_kind(), integer(), String.t(), file_upload()) ::
          {:ok, String.t()} | {:error, term()}
  def store_asset(kind, profile_id, theme_id, %{path: temp_path})
      when kind in [:image, :video, :captions] do
    with :ok <- validate_content(kind, temp_path),
         {:ok, extension} <- stored_extension(kind, temp_path),
         :ok <- strip_metadata(kind, temp_path, extension) do
      dest_dir = theme_directory(profile_id, theme_id, Map.fetch!(@kind_directories, kind))

      with {:ok, stored_name} <-
             Uploads.store_atomically(
               temp_path,
               dest_dir,
               Uploads.stored_name(extension),
               %{
                 operation: :store_theme_asset,
                 kind: kind,
                 profile_id: profile_id,
                 theme_id: theme_id
               }
             ) do
        {:ok, Path.join(dest_dir, stored_name)}
      end
    end
  end

  # Relative to the upload root, as `Uploads.store_atomically/4` takes it and
  # as the row stores it.
  defp theme_directory(profile_id, theme_id, type),
    do: Path.join(["themes", to_string(profile_id), theme_id, type])

  # Captions have one format. An image or a video is named after the format
  # its bytes are, which must also be one its kind accepts.
  defp stored_extension(:captions, _path), do: {:ok, ".vtt"}

  defp stored_extension(kind, path) do
    case detect_extension(kind, path) do
      {:ok, extension} ->
        if extension in Uploads.allowed_extensions(kind),
          do: {:ok, extension},
          else: {:error, invalid_format(kind)}

      {:error, _unrecognised} ->
        {:error, invalid_format(kind)}
    end
  end

  defp detect_extension(:image, path), do: ImageMetadata.extension(path)
  defp detect_extension(:video, path), do: VideoMetadata.extension(path)

  defp validate_content(kind, path) do
    if valid_content?(kind, path), do: :ok, else: {:error, invalid_format(kind)}
  end

  defp valid_content?(:image, path), do: MediaValidator.valid_image_file?(path)
  defp valid_content?(:video, path), do: MediaValidator.valid_video_file?(path)
  defp valid_content?(:captions, path), do: MediaValidator.valid_captions_file?(path)

  defp invalid_format(:image), do: :invalid_image_format
  defp invalid_format(:video), do: :invalid_video_format
  defp invalid_format(:captions), do: :invalid_captions_format

  # The metadata a phone writes into a photo or a recording (location,
  # capture time, device serial) would otherwise be served publicly with it.
  defp strip_metadata(:image, path, extension), do: ImageMetadata.strip(path, path, extension)

  defp strip_metadata(:video, path, _extension) do
    case VideoMetadata.strip(path) do
      {:ok, _stripped_or_unchanged} ->
        :ok

      {:error, reason} when reason in [:unsupported_container, :malformed] ->
        {:error, :invalid_video_format}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp strip_metadata(:captions, _path, _extension), do: :ok
end
