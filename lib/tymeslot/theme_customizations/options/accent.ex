defmodule Tymeslot.ThemeCustomizations.Options.Accent do
  @moduledoc """
  The accent option: one colour for the page's primary family, a preset from
  the group's `presets:` or a custom `#rrggbb`. Stored as the `accent`
  setting; nothing stored, or an id the group does not list, means the
  group's `default:`.

  An `OptionGroup`: a spec lists it as `%{key: :accent, module:
  Options.Accent, presets: [ids], default: id}`, after its palette group (and
  after `colour_mode`, where it has one), because `tokens/4` rewrites what the
  palette produced. In each colour set the groups before it produced (`vars`,
  and `dark_vars` when there are any) it replaces the primary family, the
  variables a `?primary-color=` override replaces on a palette alone:
  `--theme-primary`, fitted as text on that set's card
  (`ContrastTokens.fit_text/3`), its hover shade, and the filled-control pair
  derived from it. The card is the set's surface, or its canvas where the
  surface is not an opaque colour. A page-view `primary_color` override wins
  over the stored accent and is fitted the same way.
  """

  import Ecto.Changeset

  alias Tymeslot.ThemeCustomizations.ContrastTokens
  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.PaletteDerivation
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.Utils.Colour

  @behaviour OptionGroup

  @types %{accent: :string}

  @typedoc "An accent group: the preset ids the theme offers, in picker order, and the default."
  @type group :: %{
          required(:key) => atom(),
          required(:module) => module(),
          required(:presets) => [String.t()],
          required(:default) => String.t(),
          optional(atom()) => term()
        }

  @doc "The setting the accent stores, with its Ecto type."
  @impl OptionGroup
  def types, do: @types

  @doc "Casts the accent: one of the group's presets, or a custom colour stored as `#rrggbb`."
  @impl OptionGroup
  def changeset(changeset, attrs, %{presets: presets}) do
    changeset
    |> cast(attrs, [:accent])
    |> validate_accent(presets)
  end

  @doc """
  The changes one accent choice makes: a preset (`"preset"`) or a custom
  colour (`"custom"`) both write `accent`; the changeset validates the value.
  `:error` for any other field.
  """
  @impl OptionGroup
  def changes(field, value, _group) when field in ["preset", "custom"],
    do: {:ok, %{"accent" => value}}

  def changes(_field, _value, _group), do: :error

  @doc "The group's presets as `{id, preset}`, in the group's order."
  @spec presets(group()) :: [{String.t(), Presets.accent_preset()}]
  def presets(%{presets: ids}), do: Presets.take(:accent, ids)

  @doc """
  The stored accent: a custom `#rrggbb`, or an id the group lists. Nothing
  stored, or an id the group does not list (unknown to the catalogue, or
  dropped from `presets:`), is the group's default.
  """
  @spec choice(Spec.settings(), group()) :: String.t()
  def choice(settings, %{default: default, presets: presets}) do
    case settings["accent"] do
      "#" <> _rest = hex -> if cast_colour(hex), do: hex, else: default
      id -> if id in presets, do: id, else: default
    end
  end

  @doc "Whether a choice is a custom colour rather than a preset id."
  @spec custom?(String.t()) :: boolean()
  def custom?(choice), do: String.starts_with?(choice, "#")

  @doc """
  The accent's colour as stored, before any fitting: the preset's colour, or
  the custom one. `nil` when the choice resolves to nothing.
  """
  @spec colour(Spec.settings(), group()) :: String.t() | nil
  def colour(settings, group), do: resolve(choice(settings, group))

  @doc """
  The accent's part of a spec's tokens (`OptionGroup.tokens/4`): the primary
  family in each colour set, fitted to that set's card. A page-view
  `primary_color` wins over the stored accent. With nothing to resolve the
  sets are handed back as they came.
  """
  @impl OptionGroup
  @spec tokens(Spec.settings(), Spec.overrides(), OptionGroup.token_sets(), group()) ::
          OptionGroup.token_sets()
  def tokens(settings, overrides, %{vars: vars, dark_vars: dark_vars} = acc, group) do
    case override(overrides) || colour(settings, group) do
      nil ->
        acc

      hex ->
        %{vars: primary_family(vars, hex), dark_vars: dark_family(dark_vars, hex)}
    end
  end

  # A page without a dark set gets none from here.
  defp dark_family(dark_vars, _hex) when map_size(dark_vars) == 0, do: dark_vars
  defp dark_family(dark_vars, hex), do: primary_family(dark_vars, hex)

  defp primary_family(vars, hex) do
    primary = fit(hex, card(vars))
    hover = PaletteDerivation.hover_for(primary)

    pairs =
      ContrastTokens.derive(%{
        primary: primary,
        primary_hover: hover,
        accent: vars["--theme-accent"],
        background: vars["--theme-canvas"],
        text: vars["--theme-text"]
      })

    Map.merge(vars, %{
      "--theme-primary" => primary,
      "--theme-primary-hover" => hover,
      "--theme-on-primary" => pairs.on_primary,
      "--theme-primary-solid" => pairs.primary_solid,
      "--theme-primary-solid-hover" => pairs.primary_solid_hover
    })
  end

  # The card the primary is read on as text: the set's surface, or its canvas
  # where the surface is not an opaque hex colour. `nil` without a palette.
  defp card(vars),
    do: Enum.find([vars["--theme-surface"], vars["--theme-canvas"]], &Colour.parse_hex/1)

  defp fit(hex, nil), do: hex
  defp fit(hex, card), do: ContrastTokens.fit_text(hex, card)

  defp override(%{primary_color: hex}) when is_binary(hex), do: cast_colour(hex)
  defp override(_overrides), do: nil

  defp resolve("#" <> _rest = hex), do: cast_colour(hex)

  defp resolve(id) do
    case Presets.find_preset_by_id(:accent, id) do
      %{color: colour} -> colour
      nil -> nil
    end
  end

  defp cast_colour(hex) do
    case Colour.cast_hex(hex) do
      {:ok, normalised} -> normalised
      :error -> nil
    end
  end

  defp validate_accent(changeset, presets) do
    case get_change(changeset, :accent) do
      nil ->
        changeset

      "#" <> _rest = hex ->
        case Colour.cast_hex(hex) do
          {:ok, normalised} -> put_change(changeset, :accent, normalised)
          :error -> add_error(changeset, :accent, "must be a valid hex colour")
        end

      _id ->
        validate_inclusion(changeset, :accent, presets)
    end
  end
end
