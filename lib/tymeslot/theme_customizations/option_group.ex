defmodule Tymeslot.ThemeCustomizations.OptionGroup do
  @moduledoc """
  The contract of a customisation option group.

  A theme spec's `option_groups/0` lists group descriptors: maps carrying the
  group's `key`, the `module` implementing this behaviour, and whatever else
  that module reads from its descriptor (a background group's `kinds`, for
  instance). Shared code handles a group only through its module, so a new
  kind of option is one new module and no edit to any shared file:

    * `types/0`: the settings the group stores, with their Ecto types;
    * `changeset/3`: casts and validates them, refusing anything the
      descriptor does not offer;
    * `changes/3`: the settings one dashboard or onboarding choice writes,
      or `:error` for a field or value the group does not have;
    * `asset_fields/1` (optional): the settings that hold uploaded files and
      the kind of each. A module without it has none.
    * `media/2` (optional): what the group resolves from the stored
      settings for the theme to render, under keys of its own (merged into
      `Tokens.media` by `Specs.media/2`). A module without it has none.
    * `tokens/4` (optional): the group's custom properties. It receives what
      the groups declared before it produced and returns what the next one
      receives (`Specs.tokens/3` folds it in declaration order), so a group
      may add variables, replace another group's, or move them between the
      page set and the dark set. A module without it changes nothing.
    * `upload_changes/3` (optional): the settings an upload into one of its
      `asset_fields/1` saves. A module without it takes no uploads, even if
      it declares asset fields.
  """

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Tokens

  @typedoc "A group descriptor, as a spec's `option_groups/0` lists it."
  @type group :: %{
          required(:key) => atom(),
          required(:module) => module(),
          optional(atom()) => term()
        }

  @typedoc """
  The custom properties the groups build up, one group after another: `vars`
  for the page and `dark_vars` for a visitor whose OS is in dark mode.
  """
  @type token_sets :: %{vars: Tokens.css_vars(), dark_vars: Tokens.css_vars()}

  @doc "The settings the group stores, with their Ecto types."
  @callback types() :: %{atom() => atom()}

  @doc """
  Casts and validates the group's settings on the spec's schemaless
  changeset, refusing what `group` does not offer.
  """
  @callback changeset(Changeset.t(), map(), group()) :: Changeset.t()

  @doc """
  The settings one choice writes (`field` and `value` as the dashboard or
  onboarding send them), or `:error` for a field or value the group does not
  have.
  """
  @callback changes(field :: String.t(), value :: String.t(), group()) :: {:ok, map()} | :error

  @doc "The settings that hold uploaded files, and what each stores."
  @callback asset_fields(group()) :: [{atom(), Spec.asset_kind()}]

  @doc """
  What the group resolves from the stored settings for the theme to render,
  keyed by name, each value already safe to emit; a key with nothing to show
  may be `nil`.
  """
  @callback media(Spec.settings(), group()) :: Tokens.media()

  @doc """
  The group's part of the page's custom properties. `acc` is what the groups
  declared before it produced; the result is what the next group receives.
  A group that reads or rewrites another group's variables is therefore
  declared after it.
  """
  @callback tokens(Spec.settings(), Spec.overrides(), token_sets(), group()) :: token_sets()

  @doc """
  The settings an upload stored at `path` writes, string-keyed as saves take
  them. Only the group's own settings survive (`Specs.upload_changes/3`).
  """
  @callback upload_changes(field :: atom(), path :: String.t(), group()) :: map()

  @optional_callbacks asset_fields: 1, media: 2, tokens: 4, upload_changes: 3

  @doc "A group's upload settings; empty when its module has no `asset_fields/1`."
  @spec asset_fields(group()) :: [{atom(), Spec.asset_kind()}]
  def asset_fields(%{module: module} = group) do
    if exports?(module, :asset_fields, 1), do: module.asset_fields(group), else: []
  end

  @doc "A group's media for the stored settings; empty when its module has no `media/2`."
  @spec media(Spec.settings(), group()) :: Tokens.media()
  def media(settings, %{module: module} = group) do
    if exports?(module, :media, 2), do: module.media(settings, group), else: %{}
  end

  @doc "A group's tokens over `acc`; `acc` unchanged when its module has no `tokens/4`."
  @spec tokens(Spec.settings(), Spec.overrides(), token_sets(), group()) :: token_sets()
  def tokens(settings, overrides, acc, %{module: module} = group) do
    if exports?(module, :tokens, 4),
      do: module.tokens(settings, overrides, acc, group),
      else: acc
  end

  @doc "Whether a group takes uploads into its asset fields (its module has `upload_changes/3`)."
  @spec uploads?(group()) :: boolean()
  def uploads?(%{module: module}), do: exports?(module, :upload_changes, 3)

  # A group module is named in a spec's data, not called at compile time, so
  # it may not be loaded yet when `function_exported?/3` asks.
  defp exports?(module, function, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)
end
