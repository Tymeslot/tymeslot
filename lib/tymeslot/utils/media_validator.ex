defmodule Tymeslot.Utils.MediaValidator do
  @moduledoc """
  Utility for validating media files (images and videos) using magic bytes.
  """

  @doc """
  Validates if a binary is a supported image format using ExImageInfo.
  """
  @spec valid_image?(binary()) :: boolean()
  def valid_image?(binary) when is_binary(binary) do
    case ExImageInfo.info(binary) do
      {mime, _width, _height, _variant} when is_binary(mime) -> true
      _other -> false
    end
  end

  @spec valid_image?(any()) :: boolean()
  def valid_image?(_other), do: false

  @doc """
  Validates if a binary is specifically a PNG image using ExImageInfo.
  """
  @spec valid_png?(binary()) :: boolean()
  def valid_png?(binary) when is_binary(binary) do
    case ExImageInfo.info(binary) do
      {"image/png", _width, _height, _variant} -> true
      _other -> false
    end
  end

  @spec valid_png?(any()) :: boolean()
  def valid_png?(_other), do: false

  @doc """
  Validates if a file at the given path is a PNG image.
  """
  @spec valid_png_file?(String.t()) :: boolean()
  def valid_png_file?(path) when is_binary(path) do
    case read_header(path) do
      {:ok, binary} -> valid_png?(binary)
      _other -> false
    end
  end

  @doc """
  Validates if a binary is a supported video format using magic bytes.
  Supports MP4, WebM/MKV, and AVI.
  """
  @spec valid_video?(binary()) :: boolean()
  def valid_video?(binary) when is_binary(binary) do
    # We only need the first 16 bytes for magic byte validation
    header = binary_part(binary, 0, min(byte_size(binary), 16))
    video_header?(header)
  end

  @spec valid_video?(any()) :: boolean()
  def valid_video?(_other), do: false

  # MP4 / MOV: ftyp at offset 4
  defp video_header?(<<_a::binary-size(4), "ftyp", _rest::binary>>), do: true

  # WebM / MKV: 1A 45 DF A3
  defp video_header?(<<0x1A, 0x45, 0xDF, 0xA3, _rest::binary>>), do: true

  # AVI: RIFF .... AVI
  defp video_header?(<<"RIFF", _size::binary-size(4), "AVI ", _rest::binary>>), do: true

  # MPEG Transport Stream: 0x47
  defp video_header?(<<0x47, _rest::binary>>), do: true

  # MPEG Program Stream: 00 00 01 BA or 00 00 01 B3
  defp video_header?(<<0x00, 0x00, 0x01, 0xBA, _rest::binary>>), do: true
  defp video_header?(<<0x00, 0x00, 0x01, 0xB3, _rest::binary>>), do: true

  # Flash Video: FLV
  defp video_header?(<<"FLV", _rest::binary>>), do: true

  defp video_header?(_other), do: false

  @doc """
  Validates if a file at the given path is a supported image format.
  """
  @spec valid_image_file?(String.t()) :: boolean()
  def valid_image_file?(path) when is_binary(path) do
    case read_header(path) do
      {:ok, binary} -> valid_image?(binary)
      _other -> false
    end
  end

  @doc """
  Validates if a file at the given path is a supported video format.
  """
  @spec valid_video_file?(String.t()) :: boolean()
  def valid_video_file?(path) when is_binary(path) do
    case read_header(path) do
      {:ok, binary} -> valid_video?(binary)
      _other -> false
    end
  end

  # Reads up to 2048 header bytes from `path`, always closing the handle,
  # including when `IO.binread/2` returns `:eof` or `{:error, _}`.
  @spec read_header(String.t()) :: {:ok, binary()} | {:error, term()}
  defp read_header(path) do
    open_result =
      File.open(path, [:read, :binary], fn file ->
        case IO.binread(file, 2048) do
          binary when is_binary(binary) -> binary
          other -> {:error, other}
        end
      end)

    case open_result do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates if a binary is either a valid image or a valid video.
  """
  @spec valid_media?(binary()) :: boolean()
  def valid_media?(binary) do
    valid_image?(binary) || valid_video?(binary)
  end
end
