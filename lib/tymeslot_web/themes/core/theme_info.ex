defmodule TymeslotWeb.Themes.Core.ThemeInfo do
  @moduledoc """
  Convenience accessors over the theme system for the web layer.

  Resolves a theme's picker data (catalogue facts plus the theme module's
  `metadata/0`) and a theme id's module, through
  `TymeslotWeb.Themes.Core.Registry`. This is a
  presentation-layer concern: domain code reads theme facts from
  `Tymeslot.Themes.Catalog` instead.
  """

  alias TymeslotWeb.Themes.Core.Registry

  @doc """
  Returns every registered theme's picker data, keyed by theme id.
  """
  @spec all_themes() :: %{String.t() => map()}
  def all_themes do
    Map.new(Registry.all_themes(), fn {_key, theme} -> {theme.id, describe(theme)} end)
  end

  @doc """
  Gets a theme's picker data by id: the catalogue facts (`id`, `key`, `name`,
  `status`) merged with the theme module's `metadata/0`, its `story` and its
  `axes`.
  """
  @spec get_theme(term()) :: map() | nil
  def get_theme(id) do
    case Registry.get_theme_by_id(to_string(id)) do
      {:ok, theme} -> describe(theme)
      {:error, :theme_not_found} -> nil
    end
  end

  @doc """
  The theme module bound to an id, or `nil` for an id no theme has. Every
  bound module is compiled into the application: the Registry refuses a
  binding without a Catalog theme at build time, and the theme contract test
  loads every registered theme.
  """
  @spec get_theme_module(term()) :: module() | nil
  def get_theme_module(id) do
    case Registry.get_theme_by_id(to_string(id)) do
      {:ok, %{module: module}} -> module
      {:error, :theme_not_found} -> nil
    end
  end

  @doc """
  Gets theme name by ID.
  """
  @spec get_theme_name(term()) :: String.t()
  def get_theme_name(id) do
    case get_theme(id) do
      nil -> "Unknown"
      theme -> theme.name
    end
  end

  @doc """
  Gets theme description by ID.
  """
  @spec get_description(term()) :: String.t()
  def get_description(id) do
    case get_theme(id) do
      nil -> "A beautiful theme for your booking page."
      theme -> theme.description
    end
  end

  @doc """
  Whether `id` names a registered theme.
  """
  @spec valid_theme_id?(term()) :: boolean()
  def valid_theme_id?(id), do: Registry.valid_theme_id?(to_string(id))

  @doc """
  Theme choices for the pickers, as `{name, id}` pairs in numeric id order.

  Beta themes are left out: they are reachable by `?theme=<id>` for testing,
  but no organiser is offered one until it is `:active`. Takes the registry's
  definitions by default; passing them in is for tests.
  """
  @spec theme_options(%{atom() => map()}) :: [{String.t(), String.t()}]
  def theme_options(themes \\ Registry.all_themes()) do
    themes
    |> Map.values()
    |> Enum.reject(&(&1.status == :beta))
    |> Enum.sort_by(&String.to_integer(&1.id))
    |> Enum.map(&{&1.name, &1.id})
  end

  @doc """
  The scheduling LiveView of a theme, or `nil` for an id no theme has.
  """
  @spec get_live_view_module(term()) :: module() | nil
  def get_live_view_module(id) do
    case get_theme_module(id) do
      nil -> nil
      module -> module.live_view_module()
    end
  end

  @doc """
  The voice of a theme (its `voice/0`), or `nil` for a theme without one and
  for an id no theme has.
  """
  @spec get_voice(term()) :: module() | nil
  def get_voice(id) do
    case get_theme_module(id) do
      nil -> nil
      module -> module.voice()
    end
  end

  defp describe(theme) do
    theme
    |> Map.take([:id, :key, :name, :status])
    |> Map.merge(theme.module.metadata())
    |> Map.merge(%{story: theme.module.story(), axes: theme.module.axes()})
  end
end
