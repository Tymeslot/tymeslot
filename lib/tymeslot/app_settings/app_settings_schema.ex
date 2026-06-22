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
          google_auth_enabled: boolean() | nil,
          github_auth_enabled: boolean() | nil,
          oauth_auth_enabled: boolean() | nil,
          recaptcha_signup_enabled: boolean() | nil,
          recaptcha_booking_enabled: boolean() | nil,
          recaptcha_signup_min_score: float() | nil,
          recaptcha_booking_min_score: float() | nil,
          admin_alerts_enabled: boolean() | nil,
          admin_alert_email: String.t() | nil,
          meeting_payments_enabled: boolean() | nil,
          booking_analytics_enabled: boolean() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @editable_fields [
    :registration_enabled,
    :password_auth_enabled,
    :google_auth_enabled,
    :github_auth_enabled,
    :oauth_auth_enabled,
    :recaptcha_signup_enabled,
    :recaptcha_booking_enabled,
    :recaptcha_signup_min_score,
    :recaptcha_booking_min_score,
    :admin_alerts_enabled,
    :admin_alert_email,
    :meeting_payments_enabled,
    :booking_analytics_enabled
  ]

  @score_fields [:recaptcha_signup_min_score, :recaptcha_booking_min_score]

  # Pragmatic email pattern — same shape as the user-facing validation in
  # Tymeslot.Auth. Catches obvious typos; the upstream mail adapter does the
  # rest.
  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  schema "app_settings" do
    field(:registration_enabled, :boolean)
    field(:password_auth_enabled, :boolean)
    field(:google_auth_enabled, :boolean)
    field(:github_auth_enabled, :boolean)
    field(:oauth_auth_enabled, :boolean)
    field(:recaptcha_signup_enabled, :boolean)
    field(:recaptcha_booking_enabled, :boolean)
    field(:recaptcha_signup_min_score, :float)
    field(:recaptcha_booking_min_score, :float)
    field(:admin_alerts_enabled, :boolean)
    field(:admin_alert_email, :string)
    field(:meeting_payments_enabled, :boolean)
    field(:booking_analytics_enabled, :boolean)

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
    settings
    |> cast(normalise(attrs), @editable_fields)
    |> validate_scores()
    |> validate_admin_alert_email()
  end

  # Treat a blank string for the email override as "clear the override" so
  # the UI does not have to special-case the empty input.
  defp normalise(attrs) do
    case Map.fetch(attrs, :admin_alert_email) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> Map.put(attrs, :admin_alert_email, nil)
          trimmed -> Map.put(attrs, :admin_alert_email, trimmed)
        end

      _other ->
        attrs
    end
  end

  defp validate_scores(changeset) do
    Enum.reduce(@score_fields, changeset, fn field, acc ->
      validate_number(acc, field,
        greater_than_or_equal_to: 0.0,
        less_than_or_equal_to: 1.0
      )
    end)
  end

  defp validate_admin_alert_email(changeset) do
    case fetch_change(changeset, :admin_alert_email) do
      {:ok, nil} -> changeset
      {:ok, _email} -> validate_format(changeset, :admin_alert_email, @email_regex)
      :error -> changeset
    end
  end
end
