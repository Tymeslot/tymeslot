defmodule Tymeslot.Test.FixtureThemeSpec.Emblem do
  @moduledoc """
  The fixture theme's own option group: an emblem with a shape (a choice
  among the group's `choices:`) and an uploaded image. It implements every
  `OptionGroup` callback, the optional ones included, so the fixture proves
  that a group other than the background can own uploads and media.

  Its settings carry the theme's key as a prefix: every group of every theme
  writes into the same `settings` map of a customisation row.
  """
  @behaviour Tymeslot.ThemeCustomizations.OptionGroup

  import Ecto.Changeset

  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Validation

  @types %{fixture_emblem_shape: :string, fixture_emblem_path: :string}
  @radius %{"round" => "999px", "square" => "0"}

  @impl OptionGroup
  def types, do: @types

  @impl OptionGroup
  def changeset(changeset, attrs, %{choices: choices}) do
    changeset
    |> cast(attrs, Map.keys(@types))
    |> validate_required([:fixture_emblem_shape])
    |> validate_inclusion(:fixture_emblem_shape, choices)
  end

  @impl OptionGroup
  def changes("shape", shape, _group), do: {:ok, %{"fixture_emblem_shape" => shape}}
  def changes(_field, _value, _group), do: :error

  @impl OptionGroup
  def asset_fields(_group), do: [fixture_emblem_path: :image]

  @impl OptionGroup
  def upload_changes(:fixture_emblem_path, path, _group), do: %{"fixture_emblem_path" => path}

  @impl OptionGroup
  def media(%{"fixture_emblem_path" => path}, _group) when is_binary(path) and path != "",
    do: %{emblem: "/uploads/" <> Validation.sanitize_path(path)}

  def media(_settings, _group), do: %{}

  @doc "The emblem's corner radius as a custom property of the theme's own."
  @spec vars(map(), OptionGroup.group()) :: %{String.t() => String.t()}
  def vars(settings, _group),
    do: %{
      "--fixture-emblem-radius" => Map.get(@radius, settings["fixture_emblem_shape"], "999px")
    }
end
