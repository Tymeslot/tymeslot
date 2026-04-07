defmodule Tymeslot.DatabaseSchemas.ProfileSchema do
  @moduledoc """
  Schema for user profiles containing calendar and appointment settings.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Profiles
  alias Tymeslot.Security.FieldValidators.UsernameValidator
  alias Tymeslot.Security.Security
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.Timezones
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Themes.Core.Registry

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          username: String.t() | nil,
          full_name: String.t() | nil,
          timezone: String.t() | nil,
          buffer_minutes: integer(),
          advance_booking_days: integer(),
          min_advance_hours: integer(),
          avatar: String.t() | nil,
          booking_theme: String.t() | nil,
          has_custom_theme: boolean(),
          allowed_embed_domains: [String.t()] | nil,
          primary_calendar_integration_id: integer() | nil,
          user: Tymeslot.Auth.UserSchema.t() | Ecto.Association.NotLoaded.t(),
          primary_calendar_integration:
            Tymeslot.DatabaseSchemas.CalendarIntegrationSchema.t()
            | Ecto.Association.NotLoaded.t()
            | nil,
          theme_customization:
            ThemeCustomizationSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          meeting_types: [Tymeslot.DatabaseSchemas.MeetingTypeSchema.t()] | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "profiles" do
    field(:username, :string)
    field(:full_name, :string)
    field(:timezone, :string)
    field(:buffer_minutes, :integer, default: 15)
    field(:advance_booking_days, :integer, default: 90)
    field(:min_advance_hours, :integer, default: 3)
    field(:avatar, :string)
    field(:booking_theme, :string, default: Registry.default_theme_id())
    field(:has_custom_theme, :boolean, default: false)
    field(:allowed_embed_domains, {:array, :string}, default: ["none"])
    field(:meeting_types, {:array, :map}, virtual: true)
    belongs_to(:user, Tymeslot.Auth.UserSchema)
    belongs_to(:primary_calendar_integration, Tymeslot.DatabaseSchemas.CalendarIntegrationSchema)
    has_one(:theme_customization, ThemeCustomizationSchema, foreign_key: :profile_id)

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :user_id,
      :username,
      :full_name,
      :timezone,
      :buffer_minutes,
      :advance_booking_days,
      :min_advance_hours,
      :avatar,
      :booking_theme,
      :has_custom_theme,
      :allowed_embed_domains,
      :primary_calendar_integration_id
    ])
    |> validate_required([:user_id])
    |> validate_username()
    |> validate_timezone()
    |> validate_booking_theme()
    |> validate_embed_domains()
    |> validate_number(:buffer_minutes, Constraints.buffer_minutes_opts())
    |> validate_number(:advance_booking_days, Constraints.advance_booking_days_opts())
    |> validate_number(:min_advance_hours, Constraints.min_advance_hours_opts())
    |> unique_constraint(:username)
  end

  defp validate_username(changeset) do
    changeset
    |> validate_change(:username, fn :username, username ->
      case UsernameValidator.validate(username) do
        :ok -> []
        {:error, message} -> [username: message]
      end
    end)
    |> validate_username_not_reserved()
  end

  defp validate_username_not_reserved(changeset) do
    case get_change(changeset, :username) do
      nil ->
        changeset

      username ->
        if username in Profiles.reserved_paths() do
          add_error(changeset, :username, "is reserved")
        else
          changeset
        end
    end
  end

  defp validate_timezone(changeset) do
    case get_change(changeset, :timezone) do
      nil ->
        changeset

      timezone ->
        if Timezones.valid?(timezone) do
          changeset
        else
          add_error(changeset, :timezone, "is not a valid timezone")
        end
    end
  end

  defp validate_booking_theme(changeset) do
    valid_theme_ids = Registry.valid_theme_ids()

    validate_inclusion(changeset, :booking_theme, valid_theme_ids,
      message: "must be a valid theme"
    )
  end

  defp validate_embed_domains(changeset) do
    case get_change(changeset, :allowed_embed_domains) do
      nil ->
        changeset

      domains when is_list(domains) ->
        max_domains = 20

        if length(domains) > max_domains do
          add_error(
            changeset,
            :allowed_embed_domains,
            "cannot have more than #{max_domains} domains (currently #{length(domains)})"
          )
        else
          case Security.validate_domains(domains) do
            {:ok, validated} -> put_change(changeset, :allowed_embed_domains, validated)
            {:error, error_msg} -> add_error(changeset, :allowed_embed_domains, error_msg)
          end
        end

      _other ->
        add_error(changeset, :allowed_embed_domains, "must be a list of domains")
    end
  end

  # Removed redundant validation functions in favor of Tymeslot.Security.Security.validate_domain/1
end
