defmodule Tymeslot.ThemeCustomizations.Options.Palette do
  @moduledoc """
  The colour-palette option: a preset scheme, or a palette derived from a
  custom seed colour. Stored as the `color_scheme` and `custom_palette_seed`
  settings; a present seed is the source of truth and the scheme name is then
  left unconstrained.

  An `OptionGroup`: a spec lists it as `%{key: :palette, module:
  Options.Palette, schemes: [...]}`, `schemes` being the preset ids the theme
  offers, in the theme's presentation order (onboarding and the dashboard
  both show them in it). A preset scheme outside them is refused.

  Besides the scheme list, its group descriptor may say:

    * `follow_os: true`: a light scheme's `dark_colors` go into `dark_vars`,
      which `ThemeStyle` writes for a visitor whose OS is in dark mode.
      Default `false`: the page keeps the scheme's own colours.
    * `seed_mode: :light | :dark`: which kind of palette a custom seed
      derives. Default `:dark`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Ecto.Changeset

  alias Tymeslot.ThemeCustomizations.ContrastTokens
  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.PaletteDerivation
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Utils.Colour

  @behaviour OptionGroup

  @types %{color_scheme: :string, custom_palette_seed: :string}
  @fields Map.keys(@types)

  # Palette key -> custom property. The palette's `background` is the page's
  # base colour, `--theme-canvas`; `--theme-background` belongs to the
  # background option.
  @var_names %{
    primary: "--theme-primary",
    primary_hover: "--theme-primary-hover",
    secondary: "--theme-secondary",
    accent: "--theme-accent",
    background: "--theme-canvas",
    surface: "--theme-surface",
    text: "--theme-text",
    text_secondary: "--theme-text-secondary",
    on_primary: "--theme-on-primary",
    primary_solid: "--theme-primary-solid",
    primary_solid_hover: "--theme-primary-solid-hover",
    on_accent: "--theme-on-accent",
    accent_solid: "--theme-accent-solid"
  }

  @typedoc "Per-request overrides a single page view may apply on top of the saved palette."
  @type overrides :: %{optional(:primary_color) => String.t()}

  @typedoc "What the palette contributes to a theme's tokens."
  @type tokens :: %{vars: Tokens.css_vars(), dark_vars: Tokens.css_vars()}

  @no_tokens %{vars: %{}, dark_vars: %{}}

  @typedoc """
  A palette group: the preset scheme ids the theme offers, in its presentation
  order. `follow_os` and `seed_mode` are optional (see the moduledoc).
  """
  @type group :: %{
          required(:key) => atom(),
          required(:module) => module(),
          required(:schemes) => [String.t()],
          optional(:follow_os) => boolean(),
          optional(:seed_mode) => :light | :dark,
          optional(atom()) => term()
        }

  @doc "The settings the palette stores, with their Ecto types."
  @impl OptionGroup
  def types, do: @types

  @doc "Casts and validates the palette settings."
  @impl OptionGroup
  def changeset(changeset, attrs, group) do
    changeset
    |> cast(attrs, @fields)
    |> cast_seed()
    |> validate_scheme_unless_seeded(group.schemes)
  end

  @doc """
  The changes one palette choice makes, or `:error` for a field the palette
  does not have. Choosing a scheme drops the custom seed.
  """
  @impl OptionGroup
  def changes("scheme", scheme, _group),
    do: {:ok, %{"color_scheme" => scheme, "custom_palette_seed" => nil}}

  def changes("seed", hex, _group), do: {:ok, %{"custom_palette_seed" => hex}}
  def changes(_field, _value, _group), do: :error

  @doc """
  The palette's schemes as onboarding choices, in the group's `schemes:`
  order. Choosing one is `apply_option/4` with the `"scheme"` field; the
  choice is stored as `color_scheme`. The swatch is the scheme's primary.
  """
  @spec onboarding_choices(group()) :: Spec.onboarding_choices()
  def onboarding_choices(%{key: key} = group) do
    %{
      group: key,
      field: "scheme",
      setting: "color_scheme",
      choices:
        for {id, %{name: name, colors: %{primary: swatch}}} <- schemes(group) do
          %{value: id, name: name, swatch: swatch}
        end
    }
  end

  @doc "The group's preset schemes as `{id, scheme}`, in the group's order."
  @spec schemes(group()) :: [{String.t(), Presets.color_scheme_preset()}]
  def schemes(%{schemes: ids}), do: Presets.take(:color_scheme, ids)

  @doc """
  The active palette, in the shape of a colour-scheme preset: derived from the
  seed when one is stored (in the group's `seed_mode`, `:dark` by default),
  otherwise the named preset. `nil` when neither resolves.
  """
  @spec resolve(Spec.settings(), group()) :: Presets.color_scheme_preset() | nil
  def resolve(%{"custom_palette_seed" => seed}, group) when is_binary(seed) and seed != "",
    do: PaletteDerivation.derive_palette(seed, Map.get(group, :seed_mode, :dark))

  def resolve(%{"color_scheme" => scheme}, _group) when is_binary(scheme),
    do: Presets.find_preset_by_id(:color_scheme, scheme)

  def resolve(_settings, _group), do: nil

  @doc """
  The palette as CSS custom properties: `vars` for the page, and `dark_vars`
  for a visitor in dark mode (see `scheme_tokens/3`).

  A `:primary_color` override replaces the primary (and its hover shade)
  before the contrast pairs are derived, so filled controls stay legible on
  the override. Derived from the seed when one is stored, with or without a
  scheme name beside it (`resolve/2`); both empty when neither a seed nor a
  scheme resolves.
  """
  @spec tokens(Spec.settings(), overrides(), group()) :: tokens()
  def tokens(settings, overrides, group) when is_map(settings) and is_map(overrides) do
    case resolve(settings, group) do
      nil -> @no_tokens
      palette -> scheme_tokens(palette, overrides, group)
    end
  end

  def tokens(_settings, _overrides, _group), do: @no_tokens

  @doc """
  The palette's part of a spec's tokens (`OptionGroup.tokens/4`): `tokens/3`,
  merged over what the groups before it produced.
  """
  @impl OptionGroup
  @spec tokens(Spec.settings(), overrides(), OptionGroup.token_sets(), group()) ::
          OptionGroup.token_sets()
  def tokens(settings, overrides, %{vars: vars, dark_vars: dark_vars}, group) do
    palette = tokens(settings, overrides, group)

    %{
      vars: Map.merge(vars, palette.vars),
      dark_vars: Map.merge(dark_vars, palette.dark_vars)
    }
  end

  @doc """
  The tokens for an already resolved scheme: its `colors` as `vars`, plus the
  contrast pairs `ContrastTokens` derives from them; and its `dark_colors`, in
  the same form, as `dark_vars` when it has them and the group follows the
  visitor's OS (`follow_os: true`). Otherwise `dark_vars` is empty. A
  `:primary_color` override applies to both sets.
  """
  @spec scheme_tokens(Presets.color_scheme_preset(), overrides(), group()) :: tokens()
  def scheme_tokens(%{colors: colors} = scheme, overrides, group) do
    %{vars: colours_to_vars(colors, overrides), dark_vars: dark_vars(scheme, overrides, group)}
  end

  defp dark_vars(%{dark_colors: dark_colors}, overrides, %{follow_os: true})
       when is_map(dark_colors),
       do: colours_to_vars(dark_colors, overrides)

  defp dark_vars(_scheme, _overrides, _group), do: %{}

  # A palette's colours as `--theme-*` variables plus its contrast tokens; the
  # palette's `background` becomes `--theme-canvas`.
  defp colours_to_vars(colors, overrides) do
    colors = override_primary(colors, overrides)

    colors
    |> Map.merge(ContrastTokens.derive(colors) || %{})
    |> Enum.flat_map(fn {key, value} ->
      case Map.fetch(@var_names, key) do
        {:ok, name} -> [{name, value}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp override_primary(colors, %{primary_color: hex}) when is_binary(hex),
    do: %{colors | primary: hex, primary_hover: PaletteDerivation.hover_for(hex) || hex}

  defp override_primary(colors, _overrides), do: colors

  defp cast_seed(changeset) do
    case get_change(changeset, :custom_palette_seed) do
      nil ->
        changeset

      seed ->
        case Colour.cast_hex(seed) do
          {:ok, hex} ->
            put_change(changeset, :custom_palette_seed, hex)

          :error ->
            add_error(
              changeset,
              :custom_palette_seed,
              dgettext_noop("errors", "must be a hex colour such as #14b8a6")
            )
        end
    end
  end

  defp validate_scheme_unless_seeded(changeset, scheme_ids) do
    if get_field(changeset, :custom_palette_seed) do
      changeset
    else
      changeset
      |> validate_required([:color_scheme])
      |> validate_inclusion(:color_scheme, scheme_ids)
    end
  end
end
