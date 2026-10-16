defmodule Tymeslot.ThemeCustomizations.Options.Density do
  @moduledoc """
  The density option: comfortable or compact spacing. Stored as the
  `density` setting; nothing stored (or a value it does not know) means the
  group's `default:`.

  An `OptionGroup`: a spec lists it as `%{key: :density, module:
  Options.Density, default: "comfortable"}`. `tokens/4` sets `--density` in
  `vars` (`1` or `0.75`), the factor a theme's spacing multiplies
  (`calc(var(--space-md) * var(--density))`); `scheduling/shared/tokens.css`
  defines it as `1` for a theme without the group.
  """

  import Ecto.Changeset

  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Spec

  @behaviour OptionGroup

  @types %{density: :string}
  @choices ~w(comfortable compact)
  @factors %{"comfortable" => "1", "compact" => "0.75"}

  @typedoc "A density group: the spacing a page has until the organiser picks another."
  @type group :: %{
          required(:key) => atom(),
          required(:module) => module(),
          required(:default) => String.t(),
          optional(atom()) => term()
        }

  @doc "The setting the density stores, with its Ecto type."
  @impl OptionGroup
  def types, do: @types

  @doc "Casts the density, refusing anything but comfortable and compact."
  @impl OptionGroup
  def changeset(changeset, attrs, _group) do
    changeset
    |> cast(attrs, [:density])
    |> validate_inclusion(:density, @choices)
  end

  @doc "The changes a density choice (`\"density\"`) makes; `:error` for any other field."
  @impl OptionGroup
  def changes("density", density, _group), do: {:ok, %{"density" => density}}
  def changes(_field, _value, _group), do: :error

  @doc "The choices, in the order the dashboard offers them."
  @spec choices() :: [String.t()]
  def choices, do: @choices

  @doc "The stored density, else the group's default."
  @spec choice(Spec.settings(), group()) :: String.t()
  def choice(settings, %{default: default}) do
    case settings["density"] do
      density when density in @choices -> density
      _unset -> default
    end
  end

  @doc "The density's part of a spec's tokens (`OptionGroup.tokens/4`): the `--density` factor."
  @impl OptionGroup
  @spec tokens(Spec.settings(), Spec.overrides(), OptionGroup.token_sets(), group()) ::
          OptionGroup.token_sets()
  def tokens(settings, _overrides, %{vars: vars} = acc, group) do
    %{acc | vars: Map.put(vars, "--density", Map.fetch!(@factors, choice(settings, group)))}
  end
end
