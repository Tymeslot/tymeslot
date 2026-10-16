defmodule Tymeslot.ThemeCustomizations.Storage do
  @moduledoc """
  Handles filesystem-related operations for theme customization assets.
  Owns directory management, path building, and file storage; `store_asset/4`
  is the one way an upload is written.
  """

  require Logger
  alias Tymeslot.Media.ImageMetadata
  alias Tymeslot.Media.UploadConstraints
  alias Tymeslot.Media.VideoMetadata
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.Utils.MediaValidator
  alias TymeslotWeb.Helpers.UploadHandler

  @type file_upload :: %{required(:path) => Path.t(), required(:filename) => String.t()}

  @kind_directories %{image: "images", video: "videos", captions: "captions"}

  # A stored name's limit, prefix included; the sanitiser truncates to it.
  @max_name_bytes 255

  @doc """
  Builds an absolute file system path from a stored relative path.
  """
  @spec build_theme_file_path(String.t()) :: String.t()
  def build_theme_file_path(relative_path) do
    base_dir = get_upload_base_directory()
    Path.join(base_dir, relative_path)
  end

  @doc """
  Returns the base directory used for uploads.
  """
  @spec get_upload_base_directory() :: String.t()
  def get_upload_base_directory do
    Application.get_env(:tymeslot, :upload_directory, "uploads")
  end

  @doc """
  Returns the directory where theme assets are stored for a profile/theme/type.
  Type is one of "images" | "videos" | "captions".
  """
  @spec get_theme_upload_directory(integer(), String.t(), String.t()) :: String.t()
  def get_theme_upload_directory(profile_id, theme_id, type) do
    Path.join([get_upload_base_directory(), "themes", to_string(profile_id), theme_id, type])
  end

  @doc """
  Removes a profile's whole theme upload directory: every theme's images,
  videos and transcoded variants, whether or not a row still references them.
  """
  @spec delete_profile_directory(pos_integer()) :: :ok | {:error, File.posix(), Path.t()}
  def delete_profile_directory(profile_id) when is_integer(profile_id) do
    case File.rm_rf(
           Path.join([get_upload_base_directory(), "themes", Integer.to_string(profile_id)])
         ) do
      {:ok, _removed} -> :ok
      {:error, reason, failed_path} -> {:error, reason, failed_path}
    end
  end

  @doc """
  Ensures the given directory exists.
  Returns :ok on success, {:error, reason} on failure.
  """
  @spec ensure_directory_exists(String.t()) :: :ok | {:error, atom()}
  def ensure_directory_exists(dir_path) do
    case File.mkdir_p(dir_path) do
      :ok ->
        :ok

      {:error, :eacces} = error ->
        Logger.error("Permission denied creating directory", dir_path: dir_path)
        error

      {:error, :enospc} = error ->
        Logger.error("No space left on device for directory", dir_path: dir_path)
        error

      {:error, reason} = error ->
        Logger.error("Failed to create directory", dir_path: dir_path, reason: reason)
        error
    end
  end

  @doc """
  Stores an uploaded image, video or captions file for a profile's theme and
  returns its path relative to the upload root:
  `themes/<profile>/<theme>/images/<name>` for an image, `.../videos/<name>`
  for a video and `.../captions/<name>` for captions.

  The content is checked against `kind` by its bytes, never by the client's
  content type. The stored extension, by which `/uploads` types the file,
  comes from the kind: captions are always `.vtt`, and an image or a video
  keeps the client's extension, lower-cased, only when its kind takes it
  (`UploadConstraints.allowed_extensions/1`); any other is refused as a
  file of the wrong format. Every stored file gets a name of its own, a
  random prefix before the sanitised client name, so no two uploads share a
  path: a new upload never overwrites a file a setting still names, and
  deleting one upload's file never deletes another's.

  Before it is moved into the upload directory, the file the caller hands
  over at `temp_path` is cleaned in place: an image is re-encoded without its
  metadata (see `Tymeslot.Media.ImageMetadata`), and a video has its metadata
  removed (see `Tymeslot.Media.VideoMetadata`). A video that is not an MP4 or
  WebM the stripper can read to the end is refused as `:invalid_video_format`.
  Captions are plain text and carry no metadata.
  """
  @spec store_asset(Spec.asset_kind(), integer(), String.t(), file_upload()) ::
          {:ok, String.t()} | {:error, term()}
  def store_asset(kind, profile_id, theme_id, %{path: temp_path, filename: filename})
      when kind in [:image, :video, :captions] do
    with {:ok, extension} <- stored_extension(kind, filename),
         :ok <- validate_content(kind, temp_path) do
      directory = Map.fetch!(@kind_directories, kind)
      dest_dir = get_theme_upload_directory(profile_id, theme_id, directory)

      with :ok <- strip_metadata(kind, temp_path, extension),
           :ok <- ensure_directory_exists(dest_dir),
           {:ok, stored_name} <-
             UploadHandler.store_file_atomically(
               temp_path,
               dest_dir,
               unique_name(filename, extension),
               %{
                 operation: :store_theme_asset,
                 kind: kind,
                 profile_id: profile_id,
                 theme_id: theme_id
               }
             ) do
        {:ok, Path.join(["themes", to_string(profile_id), theme_id, directory, stored_name])}
      end
    end
  end

  # Captions have one format, so they are stored as it whatever the client
  # named them; an image or a video comes in several, which the validator
  # does not tell apart, so the client's extension must be one its kind takes.
  defp stored_extension(:captions, _filename), do: {:ok, ".vtt"}

  defp stored_extension(kind, filename) do
    extension = filename |> Path.extname() |> String.downcase()

    if extension in UploadConstraints.allowed_extensions(kind),
      do: {:ok, extension},
      else: {:error, invalid_format(kind)}
  end

  defp validate_content(kind, path) do
    if valid_content?(kind, path), do: :ok, else: {:error, invalid_format(kind)}
  end

  defp valid_content?(:image, path), do: MediaValidator.valid_image_file?(path)
  defp valid_content?(:video, path), do: MediaValidator.valid_video_file?(path)
  defp valid_content?(:captions, path), do: MediaValidator.valid_captions_file?(path)

  defp invalid_format(:image), do: :invalid_image_format
  defp invalid_format(:video), do: :invalid_video_format
  defp invalid_format(:captions), do: :invalid_captions_format

  # The prefix goes in front of the basename: `store_file_atomically/4`
  # sanitises the name with `Path.basename/1`, which would drop a prefix put in
  # front of a client name carrying a directory. The client's stem is
  # shortened first, so that the whole name fits the file-name limit and the
  # sanitiser never cuts off the stored extension, by which the file is
  # later served.
  #
  # Every byte of the stem outside `[a-zA-Z0-9_-]` becomes one `_`: the
  # media URL is built through `Validation.sanitize_path/1`, which drops
  # anything else and every `..`, so a stored `photo (1).jpg` or `a..b.png`
  # would be served under a name no file has. Dots go too, so the only dot
  # left is the extension's. The replacement is byte for byte, which keeps
  # the length budget exact.
  defp unique_name(filename, extension) do
    prefix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> "-"

    stem =
      filename
      |> Path.basename()
      |> Path.rootname()
      |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")

    budget = @max_name_bytes - byte_size(prefix) - byte_size(extension)

    prefix <> binary_part(stem, 0, min(byte_size(stem), budget)) <> extension
  end

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
