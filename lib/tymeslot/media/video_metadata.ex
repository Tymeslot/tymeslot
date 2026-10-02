defmodule Tymeslot.Media.VideoMetadata do
  @moduledoc """
  Removes metadata from uploaded MP4 and WebM videos, so a phone recording's
  location, capture time and device details are not published with it under
  `/uploads`.

  The file is edited in place and never changes size: each metadata structure
  is overwritten by a padding structure of exactly the same length (an MP4
  `free` box, a Matroska `Void` element) with its contents zeroed. Nothing
  after it moves, so the sample offsets an MP4 records, and the positions a
  WebM's seek index and cues record, all stay valid without being rewritten.
  The container formats themselves are walked by
  `Tymeslot.Media.VideoMetadata.Mp4` and `Tymeslot.Media.VideoMetadata.Webm`.

  A file that is neither, or whose structure does not parse to the end, is
  refused rather than stored with metadata nobody could vouch for.
  """

  alias Tymeslot.Media.VideoMetadata.Mp4
  alias Tymeslot.Media.VideoMetadata.Webm

  @typedoc """
  A change to the file: bytes to write at an offset, or a run of zero bytes.
  """
  @type patch :: {non_neg_integer(), binary() | {:zeros, non_neg_integer()}}

  @typedoc "Reads `length` bytes at `position`, as `:file.pread/3` does."
  @type reader :: (non_neg_integer(), non_neg_integer() ->
                     {:ok, binary()} | :eof | {:error, term()})

  @type error :: :unsupported_container | :malformed | File.posix()

  @zero_chunk_bytes 65_536

  @doc """
  Strips the metadata from the video at `path`, in place.

  Returns `{:ok, :stripped}` when something was removed and `{:ok, :unchanged}`
  when the file carried nothing to remove, so running it twice is harmless.
  """
  @spec strip(Path.t()) :: {:ok, :stripped | :unchanged} | {:error, error()}
  def strip(path) do
    case File.open(path, [:read, :write, :binary, :raw], &strip_open_file/1) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp strip_open_file(fd) do
    read = fn position, length -> :file.pread(fd, position, length) end

    with {:ok, size} <- :file.position(fd, :eof),
         {:ok, container} <- container(read),
         {:ok, patches} <- container.patches(read, size) do
      apply_patches(fd, patches)
    end
  end

  defp container(read) do
    case read.(0, 8) do
      {:ok, <<_size::binary-size(4), "ftyp">>} -> {:ok, Mp4}
      {:ok, <<0x1A, 0x45, 0xDF, 0xA3, _rest::binary>>} -> {:ok, Webm}
      {:ok, _other} -> {:error, :unsupported_container}
      :eof -> {:error, :unsupported_container}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_patches(_fd, []), do: {:ok, :unchanged}

  defp apply_patches(fd, patches) do
    case Enum.reduce_while(patches, :ok, fn patch, :ok -> write_patch(fd, patch) end) do
      :ok -> {:ok, :stripped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_patch(fd, {position, {:zeros, length}}) when length > @zero_chunk_bytes do
    with {:cont, :ok} <- write_patch(fd, {position, {:zeros, @zero_chunk_bytes}}) do
      write_patch(fd, {position + @zero_chunk_bytes, {:zeros, length - @zero_chunk_bytes}})
    end
  end

  defp write_patch(fd, {position, {:zeros, length}}),
    do: write_patch(fd, {position, :binary.copy(<<0>>, length)})

  defp write_patch(fd, {position, bytes}) do
    case :file.pwrite(fd, position, bytes) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end
end
