defmodule Tymeslot.Infrastructure.StaticCompressors.Gzip do
  @moduledoc """
  Writes `.gz` siblings for digested static assets, at zlib's maximum level.

  Replaces `Phoenix.Digester.Gzip`, which calls `:zlib.gzip/1` and is therefore
  pinned to zlib's default level 6. Level 9 buys around 2% on this app's
  assets — worth having only because a compressor module already had to exist
  for zstd, not worth the module on its own.

  Clients advertising zstd never reach these files; `.gz` is what everything
  else gets.
  """

  @behaviour Phoenix.Digester.Compressor

  alias Tymeslot.Infrastructure.StaticCompressors

  @level 9
  # 31 = a gzip container (16) around zlib's maximum window size (15), matching
  # what `:zlib.gzip/1` produces. That function takes no level, hence the
  # explicit deflate stream here.
  @window_bits 31
  @mem_level 8

  @impl Phoenix.Digester.Compressor
  def compress_file(file_path, content) do
    if StaticCompressors.compressible?(file_path) do
      {:ok, gzip(content)}
    else
      :error
    end
  end

  @impl Phoenix.Digester.Compressor
  def file_extensions, do: [".gz"]

  defp gzip(content) do
    stream = :zlib.open()

    try do
      :ok = :zlib.deflateInit(stream, @level, :deflated, @window_bits, @mem_level, :default)
      IO.iodata_to_binary(:zlib.deflate(stream, content, :finish))
    after
      :zlib.close(stream)
    end
  end
end
