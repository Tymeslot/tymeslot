defmodule Tymeslot.ThemeCustomizations.Options.Font do
  @moduledoc """
  The font option: one of the font choices in the group's `presets:`.
  Stored as the `font` setting; nothing stored means the group's `default:`.

  An `OptionGroup`: a spec lists it as `%{key: :font, module: Options.Font,
  presets: [ids], default: id}`. `tokens/4` writes
  `--theme-font-family: var(--font-stack-<id>)` and
  `--theme-font-heading: var(--font-heading-<id>)` into `vars`, never a
  family name: the stacks are CSS (`scheduling/shared/fonts.css`), and
  `ThemeStyle`'s value filter would refuse the quotes a family name needs.
  Only an id the group lists is written; anything else stored (unknown, or
  no longer in `presets:`) is the default. Fonts do
  not change with the colour mode, so the dark set is left alone.
  """

  import Ecto.Changeset

  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Spec

  @behaviour OptionGroup

  @types %{font: :string}

  @typedoc "A font group: the font ids the theme offers, in picker order, and the default."
  @type group :: %{
          required(:key) => atom(),
          required(:module) => module(),
          required(:presets) => [String.t()],
          required(:default) => String.t(),
          optional(atom()) => term()
        }

  @doc "The setting the font stores, with its Ecto type."
  @impl OptionGroup
  def types, do: @types

  @doc "Casts the font, refusing an id the group does not offer."
  @impl OptionGroup
  def changeset(changeset, attrs, %{presets: presets}) do
    changeset
    |> cast(attrs, [:font])
    |> validate_inclusion(:font, presets)
  end

  @doc "The changes a font choice (`\"font\"`) makes; `:error` for any other field."
  @impl OptionGroup
  def changes("font", id, _group), do: {:ok, %{"font" => id}}
  def changes(_field, _value, _group), do: :error

  @doc "The group's fonts as `{id, preset}`, in the group's order."
  @spec presets(group()) :: [{String.t(), Presets.font_preset()}]
  def presets(%{presets: ids}), do: Presets.take(:font, ids)

  @doc "The stored font id when the group lists it, else the group's default."
  @spec choice(Spec.settings(), group()) :: String.t()
  def choice(settings, %{default: default, presets: presets}) do
    case settings["font"] do
      id when is_binary(id) -> if id in presets, do: id, else: default
      _unset -> default
    end
  end

  @doc """
  The font's part of a spec's tokens (`OptionGroup.tokens/4`): the body and
  heading variables, pointing at the chosen font's stacks.
  """
  @impl OptionGroup
  @spec tokens(Spec.settings(), Spec.overrides(), OptionGroup.token_sets(), group()) ::
          OptionGroup.token_sets()
  def tokens(settings, _overrides, %{vars: vars} = acc, group) do
    id = choice(settings, group)

    case Presets.find_preset_by_id(:font, id) do
      nil ->
        acc

      _font ->
        %{
          acc
          | vars:
              Map.merge(vars, %{
                "--theme-font-family" => "var(--font-stack-#{id})",
                "--theme-font-heading" => "var(--font-heading-#{id})"
              })
        }
    end
  end
end
