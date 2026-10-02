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
  """

  alias Vix.Vips.Image, as: VipsImage

  # Bounds the memory a decompression bomb can claim: a few kilobytes of PNG
  # can declare a canvas of billions of pixels. 100 megapixels clears every
  # current phone camera with room to spare. For an animation it bounds the
  # sum over all frames.
  @max_pixels 100_000_000

  @keep_icc_only [:VIPS_FOREIGN_KEEP_ICC]

  # The libvips header fields that carry metadata a saver would write back out.
  # `orientation` is listed because it means the pixels are not yet upright.
  @metadata_field ~r/\A(exif-|xmp-data\z|iptc-data\z|png-comment-|gif-comment\z|orientation\z)/

  @type error :: :invalid_image_format | :image_too_large | File.posix()

  @doc """
  Writes `source_path` to `dest_path` as an `extension` image (".jpg", ".png",
  ".gif" or ".webp") with its metadata removed.

  `dest_path` may be `source_path`. The destination is replaced atomically, so
  a reader never sees a partly written file.
  """
  @spec strip(Path.t(), Path.t(), String.t()) :: :ok | {:error, error()}
  def strip(source_path, dest_path, extension) when is_binary(extension) do
    with {:ok, image} <- open(source_path),
         {:ok, upright} <- upright(image),
         {:ok, encoded} <- encode(upright, String.downcase(extension)) do
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
    with {:ok, image} <- open(path) do
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
  defp open(path) do
    with {:ok, binary} <- read(path) do
      case Image.open(binary, pages: :all) do
        {:ok, image} -> check_size(image)
        {:error, _reason} -> {:error, :invalid_image_format}
      end
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, _reason} -> {:error, :invalid_image_format}
    end
  end

  defp check_size(image) do
    if VipsImage.width(image) * VipsImage.height(image) <= @max_pixels,
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

  defp encode(image, extension) do
    case VipsImage.write_to_buffer(image, extension, keep: @keep_icc_only) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :invalid_image_format}
    end
  end

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
