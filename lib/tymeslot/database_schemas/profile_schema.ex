defmodule Tymeslot.DatabaseSchemas.ProfileSchema do
  @moduledoc """
  Schema for user profiles containing calendar and appointment settings.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.Utils.TimezoneUtils
  alias TymeslotWeb.Themes.Core.Registry

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          username: String.t() | nil,
          full_name: String.t() | nil,
          timezone: String.t(),
          buffer_minutes: integer(),
          advance_booking_days: integer(),
          min_advance_hours: integer(),
          avatar: String.t() | nil,
          booking_theme: String.t() | nil,
          has_custom_theme: boolean(),
          primary_calendar_integration_id: integer() | nil,
          user: Tymeslot.DatabaseSchemas.UserSchema.t() | Ecto.Association.NotLoaded.t(),
          primary_calendar_integration:
            Tymeslot.DatabaseSchemas.CalendarIntegrationSchema.t()
            | Ecto.Association.NotLoaded.t()
            | nil,
          theme_customization:
            ThemeCustomizationSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "profiles" do
    field(:username, :string)
    field(:full_name, :string)
    field(:timezone, :string, default: "Europe/Kyiv")
    field(:buffer_minutes, :integer, default: 15)
    field(:advance_booking_days, :integer, default: 90)
    field(:min_advance_hours, :integer, default: 3)
    field(:avatar, :string)
    field(:booking_theme, :string, default: Registry.default_theme_id())
    field(:has_custom_theme, :boolean, default: false)
    belongs_to(:user, Tymeslot.DatabaseSchemas.UserSchema)
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
      :primary_calendar_integration_id
    ])
    |> validate_required([:user_id, :timezone])
    |> validate_username()
    |> validate_timezone()
    |> validate_booking_theme()
    |> validate_number(:buffer_minutes, greater_than_or_equal_to: 0, less_than_or_equal_to: 120)
    |> validate_number(:advance_booking_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 365
    )
    |> validate_number(:min_advance_hours,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 168
    )
    |> unique_constraint(:username)
  end

  defp validate_username(changeset) do
    changeset
    |> validate_format(:username, ~r/^[a-z0-9][a-z0-9_-]{2,29}$/,
      message:
        "must be 3-30 characters long, start with a letter or number, and contain only lowercase letters, numbers, underscores, and hyphens"
    )
    |> validate_length(:username, min: 3, max: 30)
    |> validate_username_not_reserved()
  end

  defp validate_username_not_reserved(changeset) do
    reserved_usernames = [
      "admin",
      "api",
      "app",
      "auth",
      "blog",
      "dashboard",
      "dev",
      "docs",
      "help",
      "home",
      "login",
      "logout",
      "meeting",
      "meetings",
      "profile",
      "register",
      "schedule",
      "settings",
      "signup",
      "static",
      "support",
      "test",
      "user",
      "users",
      "www",
      "healthcheck",
      "assets",
      "images",
      "css",
      "js",
      "fonts",
      "about",
      "contact",
      "privacy",
      "terms"
    ]

    case get_change(changeset, :username) do
      nil ->
        changeset

      username ->
        if username in reserved_usernames do
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
        # Check if timezone is in our list of valid options
        valid_timezones =
          Enum.map(TimezoneUtils.get_all_timezone_options(), fn {_label, value} -> value end)

        if timezone in valid_timezones do
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
end
