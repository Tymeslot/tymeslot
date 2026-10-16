defmodule Tymeslot.ThemeCustomizations.Options.ColourMode do
  @moduledoc """
  The colour-mode option: whether the booking page is light, dark, or follows
  each visitor's OS. Stored as the `colour_mode` setting (`"light"`,
  `"dark"`, `"auto"`); nothing stored means the group's `default:`.

  An `OptionGroup`: a spec lists it as `%{key: :colour_mode, module:
  Options.ColourMode, default: "auto"}` right after a palette group with
  `follow_os: true`, whose light schemes carry `dark_colors`: the palette
  leaves the light set in `vars` and the dark set in `dark_vars`, and
  `tokens/4` chooses between them. `"light"` keeps `vars` and empties
  `dark_vars`; `"dark"` puts the dark set over `vars` and empties
  `dark_vars`; `"auto"` keeps both, and `ThemeStyle` writes the dark set
  inside `@media (prefers-color-scheme: dark)`. Groups declared after it,
  such as the accent, see the sets it chose.

  It also sets `--theme-color-scheme` (`light`, `dark` or `light dark`),
  which the theme's CSS reads for `color-scheme`, because `ThemeStyle`
  writes custom properties only.
  """

  import Ecto.Changeset

  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Spec

  @behaviour OptionGroup

  @types %{colour_mode: :string}
  @modes ~w(light dark auto)
  @color_schemes %{"light" => "light", "dark" => "dark", "auto" => "light dark"}

  @typedoc "A colour-mode group: the mode a page has until the organiser picks one."
  @type group :: %{
          required(:key) => atom(),
          required(:module) => module(),
          required(:default) => String.t(),
          optional(atom()) => term()
        }

  @doc "The setting the colour mode stores, with its Ecto type."
  @impl OptionGroup
  def types, do: @types

  @doc "Casts the colour mode, refusing anything but light, dark and auto."
  @impl OptionGroup
  def changeset(changeset, attrs, _group) do
    changeset
    |> cast(attrs, [:colour_mode])
    |> validate_inclusion(:colour_mode, @modes)
  end

  @doc "The changes a mode choice (`\"mode\"`) makes; `:error` for any other field."
  @impl OptionGroup
  def changes("mode", mode, _group), do: {:ok, %{"colour_mode" => mode}}
  def changes(_field, _value, _group), do: :error

  @doc "The modes, in the order the dashboard offers them."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc "The stored mode, else the group's default."
  @spec mode(Spec.settings(), group()) :: String.t()
  def mode(settings, %{default: default}) do
    case settings["colour_mode"] do
      mode when mode in @modes -> mode
      _unset -> default
    end
  end

  @doc """
  The colour mode's part of a spec's tokens (`OptionGroup.tokens/4`): the
  palette's sets as the mode shows them, and `--theme-color-scheme` in
  `vars`.
  """
  @impl OptionGroup
  @spec tokens(Spec.settings(), Spec.overrides(), OptionGroup.token_sets(), group()) ::
          OptionGroup.token_sets()
  def tokens(settings, _overrides, acc, group) do
    mode = mode(settings, group)
    %{vars: vars, dark_vars: dark_vars} = sets(acc, mode)

    %{
      vars: Map.put(vars, "--theme-color-scheme", Map.fetch!(@color_schemes, mode)),
      dark_vars: dark_vars
    }
  end

  defp sets(acc, "light"), do: %{acc | dark_vars: %{}}

  defp sets(%{vars: vars, dark_vars: dark_vars}, "dark"),
    do: %{vars: Map.merge(vars, dark_vars), dark_vars: %{}}

  defp sets(acc, "auto"), do: acc
end
