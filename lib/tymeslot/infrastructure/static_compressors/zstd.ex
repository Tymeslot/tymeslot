defmodule Tymeslot.Infrastructure.StaticCompressors.Zstd do
  @moduledoc """
  Writes `.zst` siblings for digested static assets.

  Zstandard ships with OTP 28 as `:zstd`, so this costs no dependency. The
  module is backed by a NIF that only loads when Erlang was built against
  libzstd, though, so availability is probed rather than assumed: a build on an
  Erlang without it skips zstd with a warning instead of failing. `Plug.Static`
  falls through to the `.gz` variant wherever no `.zst` exists, which makes the
  degraded deployment merely a little heavier over the wire.
  """

  @behaviour Phoenix.Digester.Compressor

  require Logger

  alias Tymeslot.Infrastructure.StaticCompressors

  # 19 is the highest level below zstd's "ultra" range. Levels 20-22 landed
  # within 0.1% of it on this app's assets for several times the CPU.
  @params %{compressionLevel: 19}

  @impl Phoenix.Digester.Compressor
  def compress_file(file_path, content) do
    if StaticCompressors.compressible?(file_path) and available?() do
      {:ok, IO.iodata_to_binary(:zstd.compress(content, @params))}
    else
      :error
    end
  end

  @impl Phoenix.Digester.Compressor
  def file_extensions, do: [".zst"]

  # Probed once per build rather than once per file, so an Erlang without zstd
  # logs a single warning instead of one per asset.
  defp available? do
    key = {__MODULE__, :available?}

    case :persistent_term.get(key, nil) do
      nil ->
        available? = probe()
        :persistent_term.put(key, available?)
        available?

      available? ->
        available?
    end
  end

  # A failed `on_load` leaves the module unloadable, so this covers both an
  # Erlang older than OTP 28 and one built without libzstd.
  defp probe do
    if Code.ensure_loaded?(:zstd) do
      true
    else
      Logger.warning(
        "zstd unavailable in this Erlang build — static assets will be served gzip-only"
      )

      false
    end
  end
end
