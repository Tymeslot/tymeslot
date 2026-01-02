defmodule TymeslotWeb.Helpers.UploadConstraints do
  @moduledoc """
  Centralized upload constraints for allowed file extensions and maximum sizes.
  Use these helpers in LiveView allow_upload, file validation, and storage layers
  to keep limits consistent and avoid drift.
  """

  @type upload_type :: :avatar | :image | :video

  # Maximum sizes (bytes)
  @max_sizes %{
    # 10MB
    avatar: 10_000_000,
    # 20MB
    image: 20_000_000,
    # 100MB
    video: 100_000_000
  }

  # Allowed extensions per type
  @extensions %{
    avatar: [".jpg", ".jpeg", ".png", ".gif", ".webp"],
    image: [".jpg", ".jpeg", ".png", ".webp"],
    video: [".mp4", ".webm", ".mov"]
  }

  @doc """
  Returns the allowed file extensions (lowercase) for a given upload type.
  """
  @spec allowed_extensions(upload_type) :: [String.t()]
  def allowed_extensions(type) when type in [:avatar, :image, :video] do
    Map.fetch!(@extensions, type)
  end

  @doc """
  Returns the maximum file size (in bytes) for a given upload type.
  """
  @spec max_file_size(upload_type) :: pos_integer()
  def max_file_size(type) when type in [:avatar, :image, :video] do
    Map.fetch!(@max_sizes, type)
  end
end
