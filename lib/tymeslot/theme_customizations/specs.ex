defmodule Tymeslot.ThemeCustomizations.Specs do
  @moduledoc """
  Questions asked of a theme's customisation spec: its option groups, the settings they store and how a stored row reads (`settings/2`), the background kinds it offers, the media and tokens its groups resolve, the group an upload belongs to, and the spec for a theme id. Kept apart from `Spec`, which a spec `use`s at compile time and must therefore depend on nothing.
  """

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Themes.Catalog

  @doc """
  The settings a spec stores, with their Ecto types: those of each of its
  option groups' modules. A stored key outside these is dropped on the next
  save.
  """
  @spec setting_types(module()) :: %{atom() => atom()}
  def setting_types(spec) do
    spec.option_groups()
    |> Enum.map(& &1.module.types())
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  @doc """
  A customisation's stored settings as the spec reads them, the one reading
  the booking page, the dashboard and every save share. For each option
  group in turn: its stored settings, or the spec's `defaults/0` for them
  when the row stores none of the group's settings, kept when the group's
  own `changeset/3` accepts them (normalised, as a save stores them), and
  otherwise the spec's defaults for that group alone.
  So a value a group no longer accepts (a preset dropped from its list, a
  kind the theme stopped offering) costs that group its choice and no other
  group anything, and a group the spec gained after the row was saved
  starts from its defaults. Keys no group declares are dropped and empty
  values left out. `use Spec` guarantees each setting belongs to one group.
  """
  @spec settings(module(), Spec.settings()) :: Spec.settings()
  def settings(spec, stored) do
    defaults = Map.new(spec.defaults(), fn {key, value} -> {Atom.to_string(key), value} end)

    Enum.reduce(spec.option_groups(), %{}, fn group, acc ->
      Map.merge(acc, group_settings(group, stored, defaults))
    end)
  end

  defp group_settings(%{module: module} = group, stored, defaults) do
    types = module.types()
    keys = Enum.map(types, fn {key, _type} -> Atom.to_string(key) end)
    own_defaults = defaults |> Map.take(keys) |> present()
    own_stored = stored |> Map.take(keys) |> present()

    # The defaults stand in for a group stored without any of its settings,
    # never key by key: a stored background kind with no value (an upload
    # saved before `background_value` was required) would otherwise take the
    # default's preset, and lose the upload it names.
    candidate = if own_stored == %{}, do: own_defaults, else: own_stored

    case accepted(group, types, candidate) do
      {:ok, settings} -> settings
      :error -> own_defaults
    end
  end

  # Every value is a change, so the group's whole changeset runs over it,
  # `validate_inclusion/3` included, with nothing of any other group's.
  defp accepted(%{module: module} = group, types, candidate) do
    empty = Map.new(types, fn {key, _type} -> {key, nil} end)
    changeset = module.changeset(Changeset.change({empty, types}), candidate, group)

    if changeset.valid? do
      {:ok,
       changeset
       |> Changeset.apply_changes()
       |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
       |> present()}
    else
      :error
    end
  end

  defp present(settings), do: Map.reject(settings, fn {_key, value} -> is_nil(value) end)

  @doc """
  The render-ready media a spec's option groups resolve from the stored
  settings: every group's `media/2`, merged in declaration order. A group
  without `media/2` contributes nothing, and a key whose value is `nil` is left
  out, so `media[:logo]` is `nil` exactly when there is no logo to render.
  """
  @spec media(module(), Spec.settings()) :: Tokens.media()
  def media(spec, settings) do
    spec.option_groups()
    |> Enum.reduce(%{}, fn group, acc -> Map.merge(acc, OptionGroup.media(settings, group)) end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  The standard tokens for a spec's stored settings and page-view overrides,
  the default `tokens/2` that `use Spec` generates: every group's `tokens/4`
  (`OptionGroup.tokens/4`), folded in declaration order from empty `vars` and
  `dark_vars`, so each group receives what the groups before it produced;
  then every group's media (`media/2`). The palette puts in its colours and
  contrast pairs, a background group after it `--theme-background`, and a
  group without `tokens/4` changes nothing. A spec with tokens of its own
  overrides `tokens/2` and starts from this.
  """
  @spec tokens(module(), Spec.settings(), Spec.overrides()) :: Tokens.t()
  def tokens(spec, settings, overrides) do
    %{vars: vars, dark_vars: dark_vars} =
      Enum.reduce(spec.option_groups(), %{vars: %{}, dark_vars: %{}}, fn group, acc ->
        OptionGroup.tokens(settings, overrides, acc, group)
      end)

    %Tokens{vars: vars, dark_vars: dark_vars, media: media(spec, settings)}
  end

  @doc """
  The option group that takes uploads into the asset field `field`, with the
  field's kind. `:error` when no group of the spec declares the field in its
  `asset_fields/1`, or when the group that does has no `upload_changes/3`.
  """
  @spec upload_group(module(), atom()) ::
          {:ok, OptionGroup.group(), Spec.asset_kind()} | :error
  def upload_group(spec, field) do
    Enum.find_value(spec.option_groups(), :error, fn group ->
      with true <- OptionGroup.uploads?(group),
           {^field, kind} <- List.keyfind(OptionGroup.asset_fields(group), field, 0) do
        {:ok, group, kind}
      else
        _other -> nil
      end
    end)
  end

  @doc """
  The settings an upload stored at `path` writes into `group`'s asset field
  `field`: the group's `upload_changes/3`, keeping only the group's own
  settings (its `types/0`), so an upload never changes another group's
  options or clears another group's files. Keys are strings, as saves take them.
  """
  @spec upload_changes(OptionGroup.group(), atom(), String.t()) :: map()
  def upload_changes(%{module: module} = group, field, path) do
    own = Enum.map(module.types(), fn {key, _type} -> Atom.to_string(key) end)

    field
    |> module.upload_changes(path, group)
    |> Map.take(own)
  end

  @doc "The spec's first option group implemented by `module`, or `nil`."
  @spec group(module(), module()) :: OptionGroup.group() | nil
  def group(spec, module), do: Enum.find(spec.option_groups(), &(&1.module == module))

  @doc """
  The onboarding choices of a spec's palette group, or `nil` when it has none:
  the default `onboarding_choices/0` that `use Spec` generates.
  """
  @spec palette_choices(module()) :: Spec.onboarding_choices()
  def palette_choices(spec) do
    case group(spec, Palette) do
      nil -> nil
      palette -> Palette.onboarding_choices(palette)
    end
  end

  @doc "The background kinds a spec declares; empty when it has no background group."
  @spec background_kinds(module()) :: [Spec.background_kind()]
  def background_kinds(spec) do
    case group(spec, Background) do
      %{kinds: kinds} -> kinds
      nil -> []
    end
  end

  @doc "Whether a spec offers the given background kind."
  @spec supports_background?(module(), Spec.background_kind()) :: boolean()
  def supports_background?(spec, kind), do: kind in background_kinds(spec)

  @doc "The spec for a theme id, falling back to the default theme's spec for an unknown id."
  @spec for_theme(String.t()) :: module()
  def for_theme(theme_id) do
    case Catalog.customization_spec(theme_id) do
      {:ok, spec} -> spec
      {:error, :theme_not_found} -> Catalog.default().customization_spec
    end
  end
end
