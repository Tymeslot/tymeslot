defmodule Tymeslot.ThemeCustomizations.ThemeCustomizationSchema do
  @moduledoc """
  Schema for user theme customizations including color schemes and backgrounds.

  The options a theme offers live in `settings`, a string-keyed map whose keys
  are the ones the theme's customisation spec declares
  (`Tymeslot.ThemeCustomizations.Specs.setting_types/1`).
  `video_processing_status` is a column of its own, outside the spec and
  outside this changeset: the processing state of each uploaded video, keyed
  by its asset field (`%{"background_video_path" => "completed"}`), written in
  place by `ThemeCustomizationQueries.update_video_processing_status/3`. The
  table's older `video_processing` column is no longer read; a later release
  drops it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ecto.Changeset
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Specs
  alias Tymeslot.Themes.Catalog

  @type t :: %__MODULE__{
          id: integer() | nil,
          profile_id: integer() | nil,
          theme_id: String.t() | nil,
          settings: Spec.settings() | nil,
          video_processing_status: %{optional(String.t()) => String.t()},
          profile: ProfileSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "theme_customizations" do
    field(:theme_id, :string)
    field(:settings, :map, default: %{})
    field(:video_processing_status, :map, default: %{})

    belongs_to(:profile, ProfileSchema, foreign_key: :profile_id)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts the shared columns and hands the theme's own settings to its
  customisation spec, which validates them (including whether the theme
  supports the option at all). `attrs` carries the settings flat, beside the
  columns (`%{"theme_id" => _, "background_type" => _}`).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(theme_customization, attrs) do
    theme_customization
    |> cast(attrs, [:profile_id, :theme_id])
    |> validate_required([:profile_id, :theme_id])
    |> apply_theme_spec(attrs)
    |> foreign_key_constraint(:profile_id)
    |> unique_constraint([:profile_id, :theme_id])
  end

  defp apply_theme_spec(changeset, attrs) do
    case get_field(changeset, :theme_id) do
      nil ->
        changeset

      theme_id ->
        case Catalog.customization_spec(theme_id) do
          {:ok, spec} -> put_settings(changeset, spec, attrs)
          {:error, :theme_not_found} -> add_error(changeset, :theme_id, "is not a valid theme")
        end
    end
  end

  # The spec validates a schemaless changeset over its own settings, starting
  # from the stored ones as `Specs.settings/2` reads them: the theme's
  # defaults for what is not stored (a row not yet inserted, or a group the
  # spec gained since), and a group's defaults in place of settings it no
  # longer accepts. So only what `attrs` changes is judged, and a stale value
  # in one group cannot block a save of another. Its errors land on the
  # parent under the setting's name, and the result replaces `settings`
  # whole, holding only the keys the spec declares and leaving out the empty
  # ones.
  defp put_settings(changeset, spec, attrs) do
    types = Specs.setting_types(spec)
    current = Specs.settings(spec, get_field(changeset, :settings) || %{})
    stored = Map.new(types, fn {key, _type} -> {key, Map.get(current, Atom.to_string(key))} end)

    settings = spec.changeset(Changeset.change({stored, types}), attrs)

    changeset =
      Enum.reduce(settings.errors, changeset, fn {key, {message, opts}}, acc ->
        add_error(acc, key, message, opts)
      end)

    put_change(
      changeset,
      :settings,
      for(
        {key, value} <- apply_changes(settings),
        value != nil,
        into: %{},
        do: {Atom.to_string(key), value}
      )
    )
  end
end
