defmodule Tymeslot.Media.ImageMetadata do
  @moduledoc """
  Re-encodes uploaded images without their metadata, so nothing a camera or
  phone embedded (EXIF GPS coordinates, capture time, device model and serial
  number, XMP, IPTC, PNG text chunks) is published with them under `/uploads`.

  The pixels are rotated upright first: stripping the EXIF Orientation tag
  without applying it would turn portrait phone photos sideways. Only the ICC
  colour profile is kept, because dropping it shifts the colours of wide-gamut
  photos and it identifies nothing.

  Animated GIF and WebP keep every frame, their timing and their loop count.
  Their frames are not auto-rotated: libvips stacks the frames into one tall
  image, which a rotation would scramble, and animations do not carry an
  orientation in practice.

  Re-encoding rather than editing the file in place also means a crafted file
  never reaches disk as it was sent. It is not a validator: callers check the
  upload's magic bytes first, and run this afterwards, so a crafted file cannot
  use the encoder to get past that check.

  Re-encoding keeps the quality the upload had. JPEG and lossy WebP are
  written at quality 90, well above the encoders' default of 75, so a stripped
  photo is not visibly worse than the one sent; a lossless WebP stays
  lossless and a palette PNG stays a palette PNG, so neither changes a pixel.
  GIF needs nothing: the encoder keeps the colours of an image that already
  has 256 or fewer exactly.

  Decoding is the expensive part, so strips run one at a time on each node:
  concurrent uploads queue rather than each claiming the memory of a full
  decode.
  """

  alias Tymeslot.Integrations.Shared.Lock
  alias Vix.Vips.Image, as: VipsImage

  # Bounds the memory a decompression bomb can claim: a few kilobytes of PNG
  # or WebP can declare a canvas of billions of pixels, and decoding costs
  # several bytes per pixel whatever the file size (a 178 KB, 100 megapixel
  # WebP took over 800 MB). 40 megapixels clears what phone cameras save by
  # default: 48 and 50 megapixel sensors bin their pixels down to 12 or 24
  # megapixel photos, and only a full-resolution mode the user picks writes
  # more. An avatar or a page background has no use for that much. For an
  # animation it bounds the sum over all frames.
  @max_pixels 40_000_000

  # WebP costs more per pixel on both sides: the decoder holds the whole
  # canvas, and the lossless encoder needs around 19 bytes a pixel (a 40
  # megapixel lossless WebP took 780 MB and 20 seconds). WebP comes from
  # export tools rather than cameras, and 16 megapixels is more than a 5K
  # display shows.
  @max_webp_pixels 16_000_000

  @keep_icc_only [:VIPS_FOREIGN_KEEP_ICC]

  # The encoders' default is 75, visibly softer than a camera's own output.
  @lossy_quality 90

  # One strip at a time per node (the lock manager is node-local), so the
  # peak memory of a decode is paid once rather than once per concurrent
  # upload. The wait is bounded so a queue of large uploads fails the late
  # ones rather than holding their LiveViews indefinitely.
  @lock_key {:image_metadata, :strip}
  @lock_wait_ms 30_000

  # The libvips header fields that carry metadata a saver would write back out.
  # `orientation` is listed because it means the pixels are not yet upright.
  @metadata_field ~r/\A(exif-|xmp-data\z|iptc-data\z|png-comment-|gif-comment\z|orientation\z)/

  @type error :: :invalid_image_format | :image_too_large | :busy | File.posix()

  @doc """
  Writes `source_path` to `dest_path` as an `extension` image (".jpg", ".png",
  ".gif" or ".webp") with its metadata removed.

  `dest_path` may be `source_path`. The destination is replaced atomically, so
  a reader never sees a partly written file.

  Returns `{:error, :busy}` when other strips kept this one waiting longer
  than 30 seconds.
  """
  @spec strip(Path.t(), Path.t(), String.t()) :: :ok | {:error, error()}
  def strip(source_path, dest_path, extension) when is_binary(extension) do
    run = fn -> do_strip(source_path, dest_path, String.downcase(extension)) end

    case Lock.with_lock(@lock_key, run, mode: :blocking, timeout: @lock_wait_ms) do
      {:error, :lock_timeout} -> {:error, :busy}
      # Outside a running application (the sweep's Mix task, a release
      # `eval`) there is no lock manager, and no uploads in this VM to wait for.
      {:error, :lock_manager_not_started} -> run.()
      result -> result
    end
  end

  defp do_strip(source_path, dest_path, extension) do
    with {:ok, binary} <- read(source_path),
         {:ok, image} <- open_binary(binary, extension),
         {:ok, upright} <- upright(image),
         {:ok, encoded} <- encode(upright, extension, saver_options(extension, image, binary)) do
      write_atomically(dest_path, encoded)
    end
  end

  @doc """
  Whether the image at `path` carries metadata `strip/3` would remove.

  For sweeping files already on disk: re-encoding a lossy format costs a
  little quality each time, so a file with nothing to remove is left alone.
  """
  @spec metadata?(Path.t()) ::
          {:ok, boolean()} | {:error, :invalid_image_format | :image_too_large}
  def metadata?(path) do
    with {:ok, image} <- open(path, String.downcase(Path.extname(path))) do
      case VipsImage.header_field_names(image) do
        {:ok, fields} -> {:ok, Enum.any?(fields, &(&1 =~ @metadata_field))}
        {:error, _reason} -> {:error, :invalid_image_format}
      end
    end
  end

  # Loaded from memory rather than by path: libvips caches what it loads by
  # file name, so reopening a file this module has just rewritten in place
  # would return the old contents. Opening only reads the header; pixels are
  # decoded when the image is encoded, which is why the size check here comes
  # before any decoding.
  defp open(path, extension) do
    with {:ok, binary} <- read(path), do: open_binary(binary, extension)
  end

  defp open_binary(binary, extension) do
    case Image.open(binary, pages: :all) do
      {:ok, image} -> check_size(image, max_pixels(binary, extension))
      {:error, _reason} -> {:error, :invalid_image_format}
    end
  end

  # The WebP bound applies whether WebP is read or written.
  defp max_pixels(<<"RIFF", _size::binary-4, "WEBP", _rest::binary>>, _extension),
    do: @max_webp_pixels

  defp max_pixels(_binary, ".webp"), do: @max_webp_pixels
  defp max_pixels(_binary, _extension), do: @max_pixels

  defp read(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, _reason} -> {:error, :invalid_image_format}
    end
  end

  defp check_size(image, max_pixels) do
    if VipsImage.width(image) * VipsImage.height(image) <= max_pixels,
      do: {:ok, image},
      else: {:error, :image_too_large}
  end

  defp upright(image) do
    if Image.pages(image) > 1 do
      {:ok, image}
    else
      case Image.autorotate(image) do
        {:ok, {rotated, _flags}} -> {:ok, rotated}
        {:error, _reason} -> {:error, :invalid_image_format}
      end
    end
  end

  defp encode(image, extension, options) do
    case VipsImage.write_to_buffer(image, extension, [keep: @keep_icc_only] ++ options) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :invalid_image_format}
    end
  end

  # The encoder settings that keep the quality of the `source` image, read
  # from its header and, for WebP, its bytes.
  defp saver_options(extension, _image, _binary) when extension in [".jpg", ".jpeg"],
    do: [Q: @lossy_quality]

  defp saver_options(".webp", _image, binary) do
    if webp_lossless?(binary), do: [lossless: true], else: [Q: @lossy_quality]
  end

  defp saver_options(".png", image, _binary) do
    case VipsImage.header_value(image, "palette") do
      {:ok, 1} -> [palette: true]
      _truecolour -> []
    end
  end

  defp saver_options(_extension, _image, _binary), do: []

  # libvips reports no header field for this, so the RIFF chunks are walked:
  # lossless image data sits in a `VP8L` chunk, either at the top level or,
  # in an animation, inside an `ANMF` frame. An animation with any lossless
  # frame is kept lossless throughout, which costs bytes but never quality.
  defp webp_lossless?(<<"RIFF", _size::little-32, "WEBP", chunks::binary>>),
    do: lossless_chunk?(chunks)

  defp webp_lossless?(_not_webp), do: false

  defp lossless_chunk?(<<"VP8L", _rest::binary>>), do: true

  defp lossless_chunk?(<<fourcc::binary-4, size::little-32, rest::binary>>)
       when byte_size(rest) >= size do
    # Chunks are padded to an even length.
    lossless_frame?(fourcc, binary_part(rest, 0, size)) or
      lossless_chunk?(binary_slice(rest, (size + rem(size, 2))..-1//1))
  end

  defp lossless_chunk?(_end_of_chunks), do: false

  # An animation frame: 16 bytes of offset, size and timing, then its chunks.
  defp lossless_frame?("ANMF", <<_frame_header::binary-16, chunks::binary>>),
    do: lossless_chunk?(chunks)

  defp lossless_frame?(_fourcc, _payload), do: false

  defp write_atomically(dest_path, encoded) do
    partial = "#{dest_path}.#{System.unique_integer([:positive])}.partial"

    with :ok <- File.write(partial, encoded),
         :ok <- File.rename(partial, dest_path) do
      :ok
    else
      {:error, reason} ->
        File.rm(partial)
        {:error, reason}
    end
  end
end
