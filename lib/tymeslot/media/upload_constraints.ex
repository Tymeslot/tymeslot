defmodule Tymeslot.Media.UploadConstraints do
  @moduledoc """
  Centralized upload constraints for allowed file extensions and maximum sizes.
  Use these helpers in LiveView allow_upload, file validation, and storage layers
  to keep limits consistent and avoid drift.
  """

  @type upload_type :: :avatar | :image | :video | :captions

  # Maximum sizes (bytes)
  @max_sizes %{
    # 10MB
    avatar: 10_000_000,
    # 20MB
    image: 20_000_000,
    # 100MB
    video: 100_000_000,
    # 200KB
    captions: 200_000
  }

  # Allowed extensions per type. QuickTime (`.mov`) is no longer accepted:
  # phones record their location into it, and only MP4 and WebM have their
  # metadata stripped on upload.
  @extensions %{
    avatar: [".jpg", ".jpeg", ".png", ".gif", ".webp"],
    image: [".jpg", ".jpeg", ".png", ".webp"],
    video: [".mp4", ".webm"],
    captions: [".vtt"]
  }

  @doc """
  Returns the allowed file extensions (lowercase) for a given upload type.
  """
  @spec allowed_extensions(upload_type) :: [String.t()]
  def allowed_extensions(type) when type in [:avatar, :image, :video, :captions] do
    Map.fetch!(@extensions, type)
  end

  @doc """
  Returns the maximum file size (in bytes) for a given upload type.
  """
  @spec max_file_size(upload_type) :: pos_integer()
  def max_file_size(type) when type in [:avatar, :image, :video, :captions] do
    Map.fetch!(@max_sizes, type)
  end

  @doc """
  Returns the maximum file size for a given upload type in whole megabytes, as
  the dashboard states it to the organiser. Captions are measured in
  kilobytes and have no megabyte figure.
  """
  @spec max_file_size_mb(:avatar | :image | :video) :: pos_integer()
  def max_file_size_mb(type) when type in [:avatar, :image, :video],
    do: div(max_file_size(type), 1_000_000)
end
