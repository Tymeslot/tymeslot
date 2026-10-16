defmodule Tymeslot.Utils.MediaValidator do
  @moduledoc """
  Utility for validating media files (images, videos and WebVTT captions) by
  their contents: magic bytes, or the signature a captions file starts with.
  """

  # Brands of an ISO base media file that name a video file: the ISO base
  # media versions, MP4 v1/v2, H.264 MP4, CMAF video, QuickTime, iTunes video,
  # MPEG-DASH segments and 3GPP/3GPP2 video.
  @video_brands ~w(isom iso2 iso3 iso4 iso5 iso6 iso7 iso8 iso9 mp41 mp42 avc1 cmfc dash) ++
                  ~w(3gp4 3gp5 3gp6 3g2a 3g2b 3g2c) ++ ["qt  ", "M4V ", "M4VH", "M4VP"]

  # Major brands of still images (HEIF/HEIC, AVIF, Canon raw) and audio
  # (iTunes and Flash audio) in the same family. Such files routinely list a
  # video brand (`mp42`, `isom`) among their compatible brands, so their major
  # brand alone must refuse them.
  @not_video_brands ~w(heic heix hevc hevx heim heis hevm hevs mif1 mif2 msf1 miaf) ++
                      ~w(avif avis avio) ++ ["crx ", "M4A ", "M4B ", "M4P ", "F4A ", "F4B "]

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

  @spec valid_png?(binary()) :: boolean()
  defp valid_png?(binary) when is_binary(binary) do
    case ExImageInfo.info(binary) do
      {"image/png", _width, _height, _variant} -> true
      _other -> false
    end
  end

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

  Recognises the containers behind the video upload allowlist (`.mp4`,
  `.webm`): Matroska/WebM (the EBML header), and the ISO base media family,
  read from the leading `ftyp` box. QuickTime's brand belongs to that family
  and passes here too: the extension allowlist, not this check, keeps `.mov`
  uploads out, and `Tymeslot.Media.VideoMetadata` then refuses any file whose
  structure it cannot walk.
  A file of that family passes when its major brand is a known video brand,
  or when the major brand is not a known image or audio brand and one of its
  compatible brands is a video brand, which admits cameras' own brands
  (Sony's `XAVC`, `MSNV`). Still images and audio of the same family (HEIC,
  AVIF, M4A) are refused, as is anything else, whatever its name: a GIF or
  an image renamed `.mp4` is never stored, served as a background video or
  queued for transcoding.
  """
  @spec valid_video?(binary()) :: boolean()
  def valid_video?(binary) when is_binary(binary), do: video_header?(binary)

  @spec valid_video?(any()) :: boolean()
  def valid_video?(_other), do: false

  # MP4 / MOV: an ftyp box at offset 4: its size, the major brand, then a
  # minor version and the compatible brands filling the rest of the box.
  defp video_header?(<<size::32, "ftyp", major::binary-size(4), rest::binary>>) do
    major in @video_brands or
      (major not in @not_video_brands and
         Enum.any?(compatible_brands(rest, size - 12), &(&1 in @video_brands)))
  end

  # WebM / MKV: 1A 45 DF A3
  defp video_header?(<<0x1A, 0x45, 0xDF, 0xA3, _rest::binary>>), do: true

  defp video_header?(_other), do: false

  # `rest` starts with the minor version; the brands follow it, up to the end
  # of the box (`length` bytes after the major brand) or of the header read.
  defp compatible_brands(rest, length) do
    case binary_part(rest, 0, min(max(length, 0), byte_size(rest))) do
      <<_minor::binary-size(4), brands::binary>> ->
        for <<brand::binary-size(4) <- brands>>, do: brand

      _no_brands ->
        []
    end
  end

  @doc """
  Whether `binary` starts as a WebVTT file must: the signature `WEBVTT`,
  after an optional UTF-8 byte order mark, followed by the end of the file,
  a space, a tab or a line break.
  """
  @spec valid_captions?(term()) :: boolean()
  def valid_captions?(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: webvtt_signature?(rest)
  def valid_captions?(binary) when is_binary(binary), do: webvtt_signature?(binary)
  def valid_captions?(_other), do: false

  defp webvtt_signature?("WEBVTT"), do: true

  defp webvtt_signature?(<<"WEBVTT", next, _rest::binary>>) when next in [?\s, ?\t, ?\n, ?\r],
    do: true

  defp webvtt_signature?(_other), do: false

  @doc """
  Validates if a file at the given path is a WebVTT captions file.
  """
  @spec valid_captions_file?(String.t()) :: boolean()
  def valid_captions_file?(path) when is_binary(path) do
    case read_header(path) do
      {:ok, binary} -> valid_captions?(binary)
      _other -> false
    end
  end

  @doc """
  Validates if a file at the given path is a supported image format.

  Reads the whole file, not just its header: a JPEG's dimensions sit in its
  SOF marker, after every APP segment, and the EXIF block of a phone photo
  (with its embedded thumbnail) or an embedded colour profile routinely pushes
  that marker well past the first few kilobytes. Image uploads are capped in
  size before they reach here.
  """
  @spec valid_image_file?(String.t()) :: boolean()
  def valid_image_file?(path) when is_binary(path) do
    case File.read(path) do
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
end
