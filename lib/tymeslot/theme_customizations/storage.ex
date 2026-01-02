defmodule Tymeslot.ThemeCustomizations.Storage do
  @moduledoc """
  Handles filesystem-related operations for theme customization assets.
  Owns directory management, path building, and file storage.
  """

  require Logger
  alias TymeslotWeb.Helpers.UploadHandler

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
  Ensures the given directory exists, raising on unrecoverable errors.
  """
  @spec ensure_directory_exists(String.t()) :: :ok
  def ensure_directory_exists(dir_path) do
    case File.mkdir_p(dir_path) do
      :ok ->
        :ok

      {:error, :eacces} ->
        Logger.error("Permission denied creating directory: #{dir_path}")
        raise "Failed to create upload directory due to permissions: #{dir_path}"

      {:error, :enospc} ->
        Logger.error("No space left on device for directory: #{dir_path}")
        raise "No space left on device to create directory: #{dir_path}"

      {:error, reason} ->
        Logger.error("Failed to create directory #{dir_path}: #{reason}")
        raise "Failed to create upload directory: #{dir_path} (#{reason})"
    end
  end

  @doc """
  Stores a background image file and returns {:ok, relative_path}.
  """
  @spec store_background_image(integer(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def store_background_image(profile_id, theme_id, %{path: temp_path, filename: filename}) do
    if File.exists?(temp_path) do
      dest_dir = get_theme_upload_directory(profile_id, theme_id, "images")
      ensure_directory_exists(dest_dir)

      case UploadHandler.store_file_atomically(
             temp_path,
             dest_dir,
             filename,
             %{operation: :store_background_image, profile_id: profile_id, theme_id: theme_id}
           ) do
        {:ok, sanitized_filename} ->
          {:ok,
           Path.join(["themes", to_string(profile_id), theme_id, "images", sanitized_filename])}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :temp_file_not_found}
    end
  end

  @doc """
  Stores a background video file and returns {:ok, relative_path}.
  """
  @spec store_background_video(integer(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def store_background_video(profile_id, theme_id, %{path: temp_path, filename: filename}) do
    dest_dir = get_theme_upload_directory(profile_id, theme_id, "videos")
    ensure_directory_exists(dest_dir)

    case UploadHandler.store_file_atomically(
           temp_path,
           dest_dir,
           filename,
           %{operation: :store_background_video, profile_id: profile_id, theme_id: theme_id}
         ) do
      {:ok, sanitized_filename} ->
        {:ok,
         Path.join(["themes", to_string(profile_id), theme_id, "videos", sanitized_filename])}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
