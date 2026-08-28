defmodule Tymeslot.Profiles.ProfileSchema do
  @moduledoc """
  Schema for user profiles containing calendar and appointment settings.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Tymeslot.ChangesetValidators.BookingLimits, only: [validate_booking_limits: 2]

  alias Tymeslot.Profiles
  alias Tymeslot.Security.FieldValidators.UsernameValidator
  alias Tymeslot.Security.Security
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.Themes.Catalog
  alias Tymeslot.Timezones

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          username: String.t() | nil,
          full_name: String.t() | nil,
          timezone: String.t() | nil,
          max_bookings_per_day: pos_integer() | nil,
          max_bookings_per_week: pos_integer() | nil,
          max_bookings_per_month: pos_integer() | nil,
          avatar: String.t() | nil,
          booking_theme: String.t() | nil,
          has_custom_theme: boolean(),
          allowed_embed_domains: [String.t()] | nil,
          booking_page_published_at: DateTime.t() | nil,
          freebusy_token: String.t() | nil,
          booking_api_token: String.t() | nil,
          primary_calendar_integration_id: integer() | nil,
          user: Tymeslot.Auth.UserSchema.t() | Ecto.Association.NotLoaded.t(),
          primary_calendar_integration:
            Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()
            | Ecto.Association.NotLoaded.t()
            | nil,
          theme_customization:
            ThemeCustomizationSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          meeting_types: [Tymeslot.MeetingTypes.MeetingTypeSchema.t()] | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "profiles" do
    field(:username, :string)
    field(:full_name, :string)
    field(:timezone, :string)
    field(:max_bookings_per_day, :integer)
    field(:max_bookings_per_week, :integer)
    field(:max_bookings_per_month, :integer)
    field(:avatar, :string)
    field(:booking_theme, :string, default: Catalog.default_id())
    field(:has_custom_theme, :boolean, default: false)
    field(:allowed_embed_domains, {:array, :string}, default: ["none"])
    field(:booking_page_published_at, :utc_datetime)
    field(:freebusy_token, :string)
    field(:booking_api_token, :string)
    field(:meeting_types, {:array, :map}, virtual: true)
    belongs_to(:user, Tymeslot.Auth.UserSchema)

    belongs_to(
      :primary_calendar_integration,
      Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
    )

    has_one(:theme_customization, ThemeCustomizationSchema, foreign_key: :profile_id)

    timestamps(type: :utc_datetime)
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
      :max_bookings_per_day,
      :max_bookings_per_week,
      :max_bookings_per_month,
      :avatar,
      :booking_theme,
      :has_custom_theme,
      :allowed_embed_domains,
      :booking_page_published_at,
      :primary_calendar_integration_id
    ])
    |> validate_required([:user_id])
    |> validate_username()
    |> validate_timezone()
    |> validate_booking_theme()
    |> validate_embed_domains()
    |> validate_booking_limits(:profiles)
    |> unique_constraint(:username)
  end

  @doc """
  Focused changeset for setting or clearing the free/busy feed token, without
  re-validating unrelated fields. A `nil` token disables the feed.
  """
  @spec freebusy_token_changeset(t(), map()) :: Ecto.Changeset.t()
  def freebusy_token_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:freebusy_token])
    |> unique_constraint(:freebusy_token)
  end

  @doc """
  Focused changeset for setting or clearing the booking API token, without
  re-validating unrelated fields. A `nil` token closes the endpoint.
  """
  @spec booking_api_token_changeset(t(), map()) :: Ecto.Changeset.t()
  def booking_api_token_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:booking_api_token])
    |> unique_constraint(:booking_api_token)
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
    valid_theme_ids = Catalog.valid_ids()

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
