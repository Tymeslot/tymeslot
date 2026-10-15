defmodule Tymeslot.Media.VideoMetadata.Webm do
  @moduledoc """
  Finds the metadata in a WebM (Matroska) file, for
  `Tymeslot.Media.VideoMetadata` to overwrite.

  Each of these elements is replaced by a `Void` element of the same length
  with its contents zeroed:

    * `Tags`: free-form metadata, where location, device and capture details
      are written;
    * `Attachments`: embedded files, such as cover art;
    * `Title` and `DateUTC` in the segment `Info`: the recording's name and
      the time it was made;
    * `CRC-32`: a checksum over its parent, which voiding a sibling would
      falsify. An element without one is valid.

  The walk is flat: it steps into the `Segment` and its `Info`, and into any
  element of unknown size, and over everything else. Browsers recording with
  `MediaRecorder` write the segment and every cluster with an unknown size,
  which ends wherever the next element that cannot be its child begins, so
  stepping into a cluster and carrying on at the same level reads it
  correctly. Matroska element IDs are unique across levels, so an ID matched
  this way can only be the element it names.
  """

  import Bitwise

  alias Tymeslot.Media.VideoMetadata

  @segment 0x18538067
  @info 0x1549A966
  @void 0xEC

  @descend [@segment, @info]
  @neutralise [
    # Tags
    0x1254C367,
    # Attachments
    0x1941A469,
    # Info > Title
    0x7BA9,
    # Info > DateUTC
    0x4461,
    # CRC-32
    0xBF
  ]

  # The longest element header: a 4-byte ID and an 8-byte size.
  @max_header_bytes 12

  @doc """
  Returns the patches that remove the metadata from a file of `size` bytes, or
  `{:error, :malformed}` when its elements do not exactly fill it.
  """
  @spec patches(VideoMetadata.reader(), non_neg_integer()) ::
          {:ok, [VideoMetadata.patch()]} | {:error, :malformed | term()}
  def patches(read, size), do: scan(read, 0, size, [])

  defp scan(_read, position, size, patches) when position == size, do: {:ok, patches}

  defp scan(read, position, size, patches) do
    with {:ok, id, header_length, data_size} <- element_header(read, position, size) do
      payload = position + header_length

      case element_action(id, data_size) do
        :descend ->
          scan(read, payload, size, patches)

        :neutralise ->
          scan(read, payload + data_size, size, void(position, payload + data_size, patches))

        :skip ->
          scan(read, payload + data_size, size, patches)

        :malformed ->
          {:error, :malformed}
      end
    end
  end

  defp element_action(id, _data_size) when id in @descend, do: :descend
  defp element_action(id, :unknown) when id in @neutralise, do: :malformed
  defp element_action(id, _data_size) when id in @neutralise, do: :neutralise
  defp element_action(_id, :unknown), do: :descend
  defp element_action(_id, _data_size), do: :skip

  defp element_header(read, position, size) do
    case read.(position, @max_header_bytes) do
      {:ok, bytes} -> parse_header(bytes, position, size)
      :eof -> {:error, :malformed}
      {:error, reason} -> {:error, reason}
    end
  end

  # An ID is a variable-length integer read with its length marker kept; a
  # size is one read with the marker removed, all value bits set meaning
  # "unknown".
  defp parse_header(bytes, position, size) do
    with {:ok, id_length} <- vint_length(bytes, 4),
         <<id::size(^id_length * 8), size_bytes::binary>> <- bytes,
         {:ok, size_length} <- vint_length(size_bytes, 8),
         <<raw_size::size(^size_length * 8), _rest::binary>> <- size_bytes do
      header_length = id_length + size_length
      data_size = data_size(raw_size, size_length)
      checked_header(id, header_length, data_size, position, size)
    else
      _malformed -> {:error, :malformed}
    end
  end

  # The length is one more than the number of leading zero bits in the first
  # byte: 0b1xxxxxxx is one byte long, 0b01xxxxxx two, and so on.
  defp vint_length(<<first, _rest::binary>>, max_length) do
    case Enum.find(1..max_length, &(first >= 0x100 >>> &1)) do
      nil -> {:error, :malformed}
      length -> {:ok, length}
    end
  end

  defp vint_length(<<>>, _max_length), do: {:error, :malformed}

  defp data_size(raw_size, length) do
    value_bits = length * 7
    value = raw_size &&& (1 <<< value_bits) - 1

    if value == (1 <<< value_bits) - 1, do: :unknown, else: value
  end

  defp checked_header(id, header_length, :unknown, position, size)
       when position + header_length <= size,
       do: {:ok, id, header_length, :unknown}

  defp checked_header(id, header_length, data_size, position, size)
       when is_integer(data_size) and position + header_length + data_size <= size,
       do: {:ok, id, header_length, data_size}

  defp checked_header(_id, _header_length, _data_size, _position, _size),
    do: {:error, :malformed}

  # A Void element covering exactly `start..element_end`: the one-byte Void ID,
  # then a size written in the fewest bytes that make the lengths add up, then
  # zeros.
  defp void(start, element_end, patches) do
    total = element_end - start
    header = <<@void>> <> void_size(total)

    [{start, header}, {start + byte_size(header), {:zeros, total - byte_size(header)}} | patches]
  end

  defp void_size(total) do
    size_length =
      Enum.find(1..8, fn length ->
        value = total - 1 - length
        value >= 0 and value < (1 <<< (length * 7)) - 1
      end)

    <<0::size(size_length - 1), 1::1, total - 1 - size_length::size(size_length * 7)>>
  end
end
