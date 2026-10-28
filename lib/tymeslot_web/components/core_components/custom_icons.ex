defmodule TymeslotWeb.Components.CoreComponents.CustomIcons do
  @moduledoc """
  Core's own icons: the marks Heroicons does not ship, such as third-party
  brand logos (`brand-slack`, `brand-github`).

  Each is a single-colour SVG in `priv/icons`, named after its file and drawn in
  `currentColor`, so it sizes and colours exactly like a heroicon. Add one only
  when no heroicon fits, and only here when Core itself renders it; an icon
  only the managed offering shows belongs in that app's own set.
  """

  alias TymeslotWeb.Components.CoreComponents.IconSource

  @dir Path.expand("../../../../priv/icons", __DIR__)
  @files IconSource.files(@dir)

  for file <- @files, do: @external_resource(Path.join(@dir, file))

  @icons IconSource.load(@dir, size: 24)

  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__?, do: IconSource.files(@dir) != @files

  @doc "Looks up a custom icon by name. Returns `{:ok, icon}` or `:error`."
  @spec fetch(String.t()) :: {:ok, IconSource.icon()} | :error
  def fetch(name), do: Map.fetch(@icons, name)

  @doc "All custom icon names."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@icons)
end
