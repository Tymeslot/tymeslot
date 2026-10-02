defmodule Tymeslot.Media.VideoMetadata.Mp4 do
  @moduledoc """
  Finds the metadata in an MP4 (ISO base media) file, for
  `Tymeslot.Media.VideoMetadata` to overwrite.

  Metadata lives in boxes the player never needs to decode the video:

    * `udta`, user data: Android's `©xyz` location, 3GPP `loci`, device and
      software names;
    * `meta`: Apple's keyed metadata, including
      `com.apple.quicktime.location.ISO6709`, and iTunes-style tags;
    * `uuid`: vendor extensions, XMP among them.

  Each is renamed `free` with its contents zeroed, at the top level, in the
  movie (`moov`) and in each track (`trak`). The creation and modification
  times in the movie, track and media headers (`mvhd`, `tkhd`, `mdhd`) record
  when the video was shot, and are zeroed, which the format defines as
  unknown.
  """

  alias Tymeslot.Media.VideoMetadata

  @descend ~w(moov trak mdia)
  @neutralise ~w(udta meta uuid)
  @timestamped ~w(mvhd tkhd mdhd)

  @doc """
  Returns the patches that remove the metadata from a file of `size` bytes, or
  `{:error, :malformed}` when its boxes do not exactly fill it.
  """
  @spec patches(VideoMetadata.reader(), non_neg_integer()) ::
          {:ok, [VideoMetadata.patch()]} | {:error, :malformed | term()}
  def patches(read, size), do: scan(read, 0, size, [])

  defp scan(_read, position, limit, patches) when position == limit, do: {:ok, patches}

  defp scan(read, position, limit, patches) do
    with {:ok, type, header_length, box_size} <- box_header(read, position, limit) do
      box = %{start: position, payload: position + header_length, end: position + box_size}

      with {:ok, patches} <- box_patches(type, read, box, patches) do
        scan(read, box.end, limit, patches)
      end
    end
  end

  defp box_patches(type, read, box, patches) when type in @descend,
    do: scan(read, box.payload, box.end, patches)

  # The type always follows the 32-bit size field, whichever form the size
  # takes, so renaming it leaves the size, and every offset, intact.
  defp box_patches(type, _read, box, patches) when type in @neutralise,
    do: {:ok, [{box.start + 4, "free"}, {box.payload, {:zeros, box.end - box.payload}} | patches]}

  defp box_patches(type, read, box, patches) when type in @timestamped do
    with {:ok, timestamps} <- timestamp_patches(read, box.payload, box.end) do
      {:ok, timestamps ++ patches}
    end
  end

  defp box_patches(_type, _read, _box, patches), do: {:ok, patches}

  # A box opens with a 32-bit size and its type. A size of 1 means a 64-bit
  # size follows the type; 0 means the box runs to the end of its parent.
  defp box_header(read, position, limit) do
    case read.(position, 16) do
      {:ok, <<1::32, type::binary-size(4), size::64, _rest::binary>>} ->
        checked_header(type, 16, size, position, limit)

      {:ok, <<0::32, type::binary-size(4), _rest::binary>>} ->
        checked_header(type, 8, limit - position, position, limit)

      {:ok, <<size::32, type::binary-size(4), _rest::binary>>} ->
        checked_header(type, 8, size, position, limit)

      {:ok, _short} ->
        {:error, :malformed}

      :eof ->
        {:error, :malformed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp checked_header(type, header_length, size, position, limit)
       when size >= header_length and position + size <= limit,
       do: {:ok, type, header_length, size}

  defp checked_header(_type, _header_length, _size, _position, _limit), do: {:error, :malformed}

  # A full box: version and flags, then the two times, 32-bit in version 0
  # and 64-bit in version 1. Already-zero times are left alone, so a second
  # pass over a stripped file changes nothing.
  defp timestamp_patches(read, payload, box_end) do
    case read.(payload, min(20, box_end - payload)) do
      {:ok, <<0, _flags::24, times::binary-size(8), _rest::binary>>} ->
        {:ok, zero_unless_zero(payload + 4, times)}

      {:ok, <<1, _flags::24, times::binary-size(16), _rest::binary>>} ->
        {:ok, zero_unless_zero(payload + 4, times)}

      {:ok, _other} ->
        {:error, :malformed}

      :eof ->
        {:error, :malformed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp zero_unless_zero(position, times) do
    if times == :binary.copy(<<0>>, byte_size(times)),
      do: [],
      else: [{position, {:zeros, byte_size(times)}}]
  end
end
