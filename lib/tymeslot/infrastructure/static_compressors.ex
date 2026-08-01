defmodule Tymeslot.Infrastructure.StaticCompressors do
  @moduledoc """
  Precompressed static asset variants written by `mix phx.digest`.

  `config :phoenix, :static_compressors` points at the modules below. Each
  writes a sibling file next to every digested asset, and `Plug.Static` serves
  whichever one the client advertises in `Accept-Encoding` (see
  `TymeslotWeb.Endpoint`, which lists them best-first):

    * `#{inspect(__MODULE__)}.Zstd` — `.zst`, around 20% smaller than gzip
    * `#{inspect(__MODULE__)}.Gzip` — `.gz`, the universal fallback

  Together they replace Phoenix's built-in `Phoenix.Digester.Gzip`, which
  compresses at zlib's default level. Compression runs once per release build,
  so the slowest settings are effectively free: decompression speed is what a
  request pays for, and that is flat across levels for both algorithms.

  Which files are worth compressing is decided by `:phoenix, :gzippable_exts`,
  the stock list of text-shaped extensions. The name predates the option being
  shared by more than one compressor; reusing it keeps a single answer to the
  question rather than a second list that has to be kept in sync.
  """

  @doc """
  Whether `path` names a file worth compressing.
  """
  @spec compressible?(Path.t()) :: boolean()
  def compressible?(path) do
    Path.extname(path) in Application.fetch_env!(:phoenix, :gzippable_exts)
  end

  @doc """
  The `Plug.Static` `:encodings` list to offer in `env`, best-first.

  Empty outside `:prod`, because that is the only environment where
  `mix phx.digest` writes the compressed siblings. Elsewhere they are whatever
  an earlier `mix assets.deploy` left on disk while the asset watchers rebuilt
  the plain file around them, and `Plug.Static` prefers an encoded file whenever
  one exists rather than comparing timestamps — so offering them serves stale
  CSS and JS.

  Overlays contributing their own `:extra_static_sources` must apply the same
  rule; see `TymeslotWeb.Plugs.ExtraStatic`.
  """
  @spec encodings(atom()) :: [{String.t(), String.t()}]
  def encodings(:prod), do: [{"zstd", ".zst"}, {"gzip", ".gz"}]
  def encodings(_env), do: []
end
