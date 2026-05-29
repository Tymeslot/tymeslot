defmodule Tymeslot.Themes.Catalog do
  @moduledoc """
  Domain source of truth for theme *facts* — which themes exist and what they
  can do.

  Holds each theme's id, key, name, description, capability `features`, and
  status. This is pure data with no web or presentation dependency: profiles and
  theme customizations validate and drive behaviour off these facts without ever
  reaching up into the web layer.

  The web layer (`TymeslotWeb.Themes.Core.Registry`) augments these facts with
  presentation bindings (the theme module, CSS file, preview image), but the
  facts themselves live here so the dependency only ever flows web → domain.
  """

  @type theme_id :: String.t()
  @type theme_key :: atom()
  @type status :: :active | :beta | :deprecated
  @type theme_facts :: %{
          id: theme_id(),
          key: theme_key(),
          name: String.t(),
          description: String.t(),
          features: map(),
          status: status()
        }

  @themes %{
    quill: %{
      id: "1",
      key: :quill,
      name: "Quill",
      description: "Professional glassmorphism theme with elegant transparency effects",
      features: %{
        supports_video_background: true,
        supports_image_background: true,
        supports_gradient_background: true,
        supports_custom_colors: true,
        flow_type: :multi_step,
        step_count: 4
      },
      status: :active
    },
    rhythm: %{
      id: "2",
      key: :rhythm,
      name: "Rhythm",
      description: "Modern sliding theme with immersive video backgrounds",
      features: %{
        supports_video_background: true,
        supports_image_background: true,
        supports_gradient_background: true,
        supports_custom_colors: true,
        flow_type: :multi_step,
        step_count: 4
      },
      status: :active
    }
  }

  @default_key :quill

  # Compile-time reverse lookups
  @id_to_key_map @themes
                 |> Enum.map(fn {key, theme} -> {theme.id, key} end)
                 |> Map.new()

  @id_to_facts_map @themes
                   |> Enum.map(fn {_key, theme} -> {theme.id, theme} end)
                   |> Map.new()

  @doc """
  Returns all theme facts keyed by theme key.
  """
  @spec all() :: %{theme_key() => theme_facts()}
  def all, do: @themes

  @doc """
  Returns the facts for all active themes (excludes beta and deprecated).
  """
  @spec active() :: %{theme_key() => theme_facts()}
  def active do
    @themes
    |> Enum.filter(fn {_key, theme} -> theme.status == :active end)
    |> Map.new()
  end

  @doc """
  Gets theme facts by ID.
  """
  @spec get_by_id(theme_id()) :: {:ok, theme_facts()} | {:error, :theme_not_found}
  def get_by_id(id) when is_binary(id) do
    case Map.get(@id_to_facts_map, id) do
      nil -> {:error, :theme_not_found}
      facts -> {:ok, facts}
    end
  end

  @doc """
  Gets theme facts by key.
  """
  @spec get_by_key(theme_key()) :: {:ok, theme_facts()} | {:error, :theme_not_found}
  def get_by_key(key) when is_atom(key) do
    case Map.get(@themes, key) do
      nil -> {:error, :theme_not_found}
      facts -> {:ok, facts}
    end
  end

  @doc """
  Converts a theme ID to its key.
  """
  @spec id_to_key(theme_id()) :: {:ok, theme_key()} | {:error, :invalid_theme_id}
  def id_to_key(id) when is_binary(id) do
    case Map.get(@id_to_key_map, id) do
      nil -> {:error, :invalid_theme_id}
      key -> {:ok, key}
    end
  end

  @doc """
  Converts a theme key to its ID.
  """
  @spec key_to_id(theme_key()) :: {:ok, theme_id()} | {:error, :invalid_theme_key}
  def key_to_id(key) when is_atom(key) do
    case Map.get(@themes, key) do
      nil -> {:error, :invalid_theme_key}
      %{id: id} -> {:ok, id}
    end
  end

  @doc """
  Returns the sorted list of valid theme IDs.
  """
  @spec valid_ids() :: [theme_id()]
  def valid_ids do
    @themes
    |> Map.values()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  @doc """
  Returns the sorted list of valid theme keys.
  """
  @spec valid_keys() :: [theme_key()]
  def valid_keys do
    @themes
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  Checks whether a theme ID is registered.
  """
  @spec valid_id?(theme_id()) :: boolean()
  def valid_id?(id) when is_binary(id), do: Map.has_key?(@id_to_facts_map, id)

  @doc """
  Checks whether a theme key is registered.
  """
  @spec valid_key?(theme_key()) :: boolean()
  def valid_key?(key) when is_atom(key), do: Map.has_key?(@themes, key)

  @doc """
  Returns the default theme's facts (Quill).
  """
  @spec default() :: theme_facts()
  def default, do: Map.fetch!(@themes, @default_key)

  @doc """
  Returns the default theme ID.
  """
  @spec default_id() :: theme_id()
  def default_id, do: default().id

  @doc """
  Returns the default theme key.
  """
  @spec default_key() :: theme_key()
  def default_key, do: default().key

  @doc """
  Returns the capability features map for a theme ID.
  """
  @spec features_for(theme_id()) :: {:ok, map()} | {:error, :theme_not_found}
  def features_for(id) when is_binary(id) do
    case get_by_id(id) do
      {:ok, %{features: features}} -> {:ok, features}
      error -> error
    end
  end

  @doc """
  Returns the facts for every theme whose features map enables `feature`.
  """
  @spec themes_with_feature(atom()) :: [theme_facts()]
  def themes_with_feature(feature) when is_atom(feature) do
    @themes
    |> Map.values()
    |> Enum.filter(fn theme -> Map.get(theme.features, feature, false) == true end)
  end
end
