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

  alias Tymeslot.Locales
  alias Tymeslot.Utils.Colour

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
          email_brand_accent: String.t() | nil,
          email_brand_name: String.t() | nil,
          email_logo_path: String.t() | nil,
          admin_default_locale: String.t() | nil,
          booking_default_locale: String.t() | nil,
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
    :booking_analytics_enabled,
    :email_brand_accent,
    :email_brand_name,
    :email_logo_path,
    :admin_default_locale,
    :booking_default_locale
  ]

  @locale_fields [:admin_default_locale, :booking_default_locale]

  @score_fields [:recaptcha_signup_min_score, :recaptcha_booking_min_score]

  # Free-text overrides where an empty input means "clear the override"
  # rather than "store an empty string", so the UI can submit a blanked
  # field without special-casing it.
  @blankable_fields [
    :admin_alert_email,
    :email_brand_accent,
    :email_brand_name,
    :email_logo_path,
    :admin_default_locale,
    :booking_default_locale
  ]

  # Pragmatic email pattern — same shape as the user-facing validation in
  # Tymeslot.Auth. Catches obvious typos; the upstream mail adapter does the
  # rest.
  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  # A brand name lands in the inbox preview line and the organiser strip, both
  # of which are truncated by mail clients well before this; the cap only stops
  # an accidental paste of something enormous.
  @max_brand_name_length 60

  # The column is a bare `:string`, i.e. `varchar(255)` — a byte limit, not a
  # grapheme limit. `validate_length/3` counts graphemes by default, so a
  # 60-grapheme multi-byte name (emoji, Devanagari, Thai, ...) can pass the
  # display cap above yet still overflow storage. Validate bytes too so that
  # case is rejected with a changeset error instead of a Postgres crash.
  @max_brand_name_bytes 255

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
    field(:email_brand_accent, :string)
    field(:email_brand_name, :string)
    field(:email_logo_path, :string)
    field(:admin_default_locale, :string)
    field(:booking_default_locale, :string)

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
    |> validate_brand_accent()
    |> validate_brand_name()
    |> validate_logo_path()
    |> validate_locales()
  end

  # Trim every free-text override, treating a blank result as "clear the
  # override" so the UI does not have to special-case an emptied input.
  defp normalise(attrs) do
    Enum.reduce(@blankable_fields, attrs, fn field, acc ->
      case Map.fetch(acc, field) do
        {:ok, value} when is_binary(value) ->
          Map.put(acc, field, blank_to_nil(value))

        _absent_or_already_nil ->
          acc
      end
    end)
  end

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
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

  # Stored normalised to lowercase `#rrggbb` so everything downstream — the
  # derivation cache key, the colour input, the preview swatch — compares and
  # renders one form rather than three.
  defp validate_brand_accent(changeset) do
    case fetch_change(changeset, :email_brand_accent) do
      {:ok, nil} ->
        changeset

      {:ok, value} ->
        case Colour.normalise_hex(value) do
          nil ->
            add_error(changeset, :email_brand_accent, "must be a hex colour such as #14b8a6")

          hex ->
            put_change(changeset, :email_brand_accent, hex)
        end

      :error ->
        changeset
    end
  end

  defp validate_brand_name(changeset) do
    changeset
    |> validate_length(:email_brand_name, max: @max_brand_name_length)
    |> validate_length(:email_brand_name, max: @max_brand_name_bytes, count: :bytes)
  end

  # The stored path is relative to the configured upload directory and is
  # written only by `Tymeslot.Emails.Branding`. Rejecting absolute paths and
  # traversal here is defence in depth: it means no value that could escape
  # the upload directory can reach the row at all, whatever writes it.
  defp validate_logo_path(changeset) do
    case fetch_change(changeset, :email_logo_path) do
      {:ok, nil} ->
        changeset

      {:ok, path} ->
        if Path.type(path) == :relative and not traversal?(path) do
          changeset
        else
          add_error(changeset, :email_logo_path, "must be a relative path inside the upload dir")
        end

      :error ->
        changeset
    end
  end

  # The supported set is configuration, so it is read at validation time
  # rather than baked into the module: an install that has removed a language
  # must not be able to select it. Nil is the cleared override and passes
  # untouched: `validate_inclusion/3` only sees a change that is present.
  defp validate_locales(changeset) do
    Enum.reduce(@locale_fields, changeset, fn field, acc ->
      validate_inclusion(acc, field, Locales.supported_codes(),
        message: "is not a supported language"
      )
    end)
  end

  defp traversal?(path), do: ".." in Path.split(path)
end
