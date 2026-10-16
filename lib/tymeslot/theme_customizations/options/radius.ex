defmodule Tymeslot.ThemeCustomizations.Options.Radius do
  @moduledoc """
  The corner option: sharp, soft or round controls and cards. Stored as the
  `radius` setting; nothing stored (or a value it does not know) means the
  group's `default:`.

  An `OptionGroup`: a spec lists it as `%{key: :radius, module:
  Options.Radius, default: "soft"}`. `tokens/4` sets the two radius roles
  every theme defines, `--radius-control` and `--radius-card`, in `vars`; a
  theme that declares the group gets them from here, over its own
  `variables.css`.
  """

  import Ecto.Changeset

  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Spec

  @behaviour OptionGroup

  @types %{radius: :string}
  @choices ~w(sharp soft round)
  @lengths %{
    "sharp" => %{control: "2px", card: "4px"},
    "soft" => %{control: "8px", card: "12px"},
    "round" => %{control: "999px", card: "20px"}
  }

  @typedoc "A radius group: the corners a page has until the organiser picks others."
  @type group :: %{
          required(:key) => atom(),
          required(:module) => module(),
          required(:default) => String.t(),
          optional(atom()) => term()
        }

  @doc "The setting the radius stores, with its Ecto type."
  @impl OptionGroup
  def types, do: @types

  @doc "Casts the radius, refusing anything but sharp, soft and round."
  @impl OptionGroup
  def changeset(changeset, attrs, _group) do
    changeset
    |> cast(attrs, [:radius])
    |> validate_inclusion(:radius, @choices)
  end

  @doc "The changes a radius choice (`\"radius\"`) makes; `:error` for any other field."
  @impl OptionGroup
  def changes("radius", radius, _group), do: {:ok, %{"radius" => radius}}
  def changes(_field, _value, _group), do: :error

  @doc "The choices, in the order the dashboard offers them."
  @spec choices() :: [String.t()]
  def choices, do: @choices

  @doc "The stored radius, else the group's default."
  @spec choice(Spec.settings(), group()) :: String.t()
  def choice(settings, %{default: default}) do
    case settings["radius"] do
      radius when radius in @choices -> radius
      _unset -> default
    end
  end

  @doc "The control and card radius of a choice."
  @spec lengths(String.t()) :: %{control: String.t(), card: String.t()}
  def lengths(choice), do: Map.fetch!(@lengths, choice)

  @doc "The radius's part of a spec's tokens (`OptionGroup.tokens/4`): the two radius roles."
  @impl OptionGroup
  @spec tokens(Spec.settings(), Spec.overrides(), OptionGroup.token_sets(), group()) ::
          OptionGroup.token_sets()
  def tokens(settings, _overrides, %{vars: vars} = acc, group) do
    %{control: control, card: card} = lengths(choice(settings, group))

    %{acc | vars: Map.merge(vars, %{"--radius-control" => control, "--radius-card" => card})}
  end
end
