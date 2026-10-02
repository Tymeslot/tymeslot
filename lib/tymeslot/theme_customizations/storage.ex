defmodule Tymeslot.ThemeCustomizations.Storage do
  @moduledoc """
  Handles filesystem-related operations for theme customization assets.
  Owns directory management, path building, and file storage.
  """

  require Logger
  alias Tymeslot.Media.ImageMetadata
  alias Tymeslot.Media.VideoMetadata
  alias Tymeslot.Utils.MediaValidator
  alias TymeslotWeb.Helpers.UploadHandler

  @type file_upload :: %{required(:path) => Path.t(), required(:filename) => String.t()}

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
  Type is one of "images" | "videos".
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
  Stores a background image file and returns {:ok, relative_path}.

  The image is re-encoded without its metadata (see
  `Tymeslot.Media.ImageMetadata`) in place at `temp_path`, which the caller
  hands over: it is moved into the upload directory.
  """
  @spec store_background_image(integer(), String.t(), file_upload()) ::
          {:ok, String.t()} | {:error, term()}
  def store_background_image(profile_id, theme_id, %{path: temp_path, filename: filename}) do
    if MediaValidator.valid_image_file?(temp_path) do
      dest_dir = get_theme_upload_directory(profile_id, theme_id, "images")

      with :ok <- ImageMetadata.strip(temp_path, temp_path, Path.extname(filename)),
           :ok <- ensure_directory_exists(dest_dir),
           {:ok, sanitized_filename} <-
             UploadHandler.store_file_atomically(
               temp_path,
               dest_dir,
               filename,
               %{operation: :store_background_image, profile_id: profile_id, theme_id: theme_id}
             ) do
        {:ok,
         Path.join(["themes", to_string(profile_id), theme_id, "images", sanitized_filename])}
      end
    else
      {:error, :invalid_image_format}
    end
  end

  @doc """
  Stores a background video file and returns {:ok, relative_path}.

  The video's metadata is removed (see `Tymeslot.Media.VideoMetadata`) in
  place at `temp_path`, which the caller hands over: it is moved into the
  upload directory. A file that is not an MP4 or WebM the stripper can read
  to the end is refused as `:invalid_video_format`.
  """
  @spec store_background_video(integer(), String.t(), file_upload()) ::
          {:ok, String.t()} | {:error, term()}
  def store_background_video(profile_id, theme_id, %{path: temp_path, filename: filename}) do
    if MediaValidator.valid_video_file?(temp_path) do
      dest_dir = get_theme_upload_directory(profile_id, theme_id, "videos")

      with {:ok, _stripped_or_unchanged} <- strip_video(temp_path),
           :ok <- ensure_directory_exists(dest_dir),
           {:ok, sanitized_filename} <-
             UploadHandler.store_file_atomically(
               temp_path,
               dest_dir,
               filename,
               %{operation: :store_background_video, profile_id: profile_id, theme_id: theme_id}
             ) do
        {:ok,
         Path.join(["themes", to_string(profile_id), theme_id, "videos", sanitized_filename])}
      end
    else
      {:error, :invalid_video_format}
    end
  end

  defp strip_video(path) do
    case VideoMetadata.strip(path) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} when reason in [:unsupported_container, :malformed] ->
        {:error, :invalid_video_format}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
