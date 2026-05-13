defmodule Tymeslot.AppSettings.AppSettingsSchema do
  @moduledoc """
  Schema for the singleton `app_settings` row that stores admin-editable
  runtime overrides for values that would otherwise come from config.exs /
  environment variables.

  Each field is nullable — `nil` means "no DB override, fall back to the
  application config default". The table is constrained to a single row via
  a `CHECK (id = 1)` constraint defined in the migration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          registration_enabled: boolean() | nil,
          password_auth_enabled: boolean() | nil,
          video_transcoding_enabled: boolean() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @editable_fields [:registration_enabled, :password_auth_enabled, :video_transcoding_enabled]

  schema "app_settings" do
    field(:registration_enabled, :boolean)
    field(:password_auth_enabled, :boolean)
    field(:video_transcoding_enabled, :boolean)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the list of admin-editable setting keys.
  """
  @spec editable_fields() :: [atom()]
  def editable_fields, do: @editable_fields

  @doc """
  Changeset for updating one or more admin-editable settings.
  Each cast value may be `nil` to clear the override and fall back to the
  application config default.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(settings, attrs) do
    cast(settings, attrs, @editable_fields)
  end
end
