defmodule Tymeslot.Profiles.ProfileSchema do
  @moduledoc """
  Schema for user profiles containing calendar and appointment settings.

  Besides `changeset/2`, focused changesets cover single concerns:
  `booking_text_changeset/2`, `intro_changeset/2`, `legal_links_changeset/2`
  and `booking_languages_changeset/2`.
  """
  use Gettext, backend: TymeslotWeb.Gettext
  use Ecto.Schema
  import Ecto.Changeset
  import Tymeslot.ChangesetValidators.BookingLimits, only: [validate_booking_limits: 2]

  alias Tymeslot.ChangesetValidators.URL, as: URLValidator
  alias Tymeslot.ContentTranslations.Languages
  alias Tymeslot.Locales
  alias Tymeslot.Profiles.ReservedPaths
  alias Tymeslot.Security.EncryptedString
  alias Tymeslot.Security.FieldValidators.UsernameValidator
  alias Tymeslot.Security.Security
  alias Tymeslot.Security.Token
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.Themes.Catalog
  alias Tymeslot.Timezones
  alias Tymeslot.Validation.Constraints

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
          booking_link_first_shared_at: DateTime.t() | nil,
          last_charge_currency: String.t() | nil,
          booking_text_enabled: boolean(),
          booking_heading: String.t() | nil,
          booking_page: map() | nil,
          booking_greeting: String.t() | nil,
          booking_instruction: String.t() | nil,
          headline: String.t() | nil,
          bio: String.t() | nil,
          legal_notice_url: String.t() | nil,
          privacy_policy_url: String.t() | nil,
          content_locale: String.t() | nil,
          translation_locales: [String.t()],
          offer_all_locales: boolean(),
          translations: map(),
          freebusy_token: String.t() | nil,
          freebusy_token_hash: String.t() | nil,
          primary_calendar_integration_id: integer() | nil,
          user: Tymeslot.Auth.UserSchema.t() | Ecto.Association.NotLoaded.t(),
          primary_calendar_integration:
            Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()
            | Ecto.Association.NotLoaded.t()
            | nil,
          theme_customizations: [ThemeCustomizationSchema.t()] | Ecto.Association.NotLoaded.t(),
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
    field(:booking_link_first_shared_at, :utc_datetime)
    # The currency the host's prices were set in, kept across a disconnect:
    # `price_cents` carries no currency of its own.
    field(:last_charge_currency, :string)
    field(:booking_text_enabled, :boolean, default: false)
    field(:booking_heading, :string)
    field(:booking_greeting, :string)
    field(:booking_instruction, :string)
    field(:headline, :string)
    field(:bio, :string)
    field(:legal_notice_url, :string)
    field(:privacy_policy_url, :string)

    # The booking languages (`Tymeslot.ContentTranslations.Languages`): the
    # language the organiser writes in (nil means the booking pages'
    # fallback), the languages they translate into, and whether the booking
    # page is offered in every interface language or only in those.
    field(:content_locale, :string)
    field(:translation_locales, {:array, :string}, default: [])
    field(:offer_all_locales, :boolean, default: true)
    # Translations of the booking texts and the intro
    # (`Tymeslot.ContentTranslations`). No changeset here casts it, so a form
    # save can never wipe it.
    field(:translations, :map, default: %{})

    # Grants read access to the host's busy times, and the host copies the
    # feed URL from the dashboard again whenever they like, so it is
    # encrypted rather than only hashed; the feed looks it up by
    # `freebusy_token_hash`.
    field(:freebusy_token, EncryptedString, source: :freebusy_token_encrypted, redact: true)
    field(:freebusy_token_hash, :string)

    field(:meeting_types, {:array, :map}, virtual: true)
    # Set when this profile was resolved through one of its booking pages:
    # the page whose theme and texts `Tymeslot.BookingPages.apply_to_profile/2`
    # laid over these fields. Never persisted.
    field(:booking_page, :map, virtual: true)
    belongs_to(:user, Tymeslot.Auth.UserSchema)

    belongs_to(
      :primary_calendar_integration,
      Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
    )

    has_many(:theme_customizations, ThemeCustomizationSchema, foreign_key: :profile_id)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for inserting a user's profile. A second profile for the same
  user, or one for a user deleted meanwhile, comes back as a changeset error
  on `:user_id` rather than raising.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:user_id, :full_name])
    |> validate_required([:user_id])
    |> validate_length(:full_name, max: 255)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end

  # One changeset per kind of write, so each casts only what that write may
  # change: no update path can reassign `user_id` or the published stamp, and
  # an unrelated save never re-runs another field's validation.

  @doc "The host's name and time zone."
  @spec basic_changeset(t(), map()) :: Ecto.Changeset.t()
  def basic_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:full_name, :timezone])
    # The column is a varchar(255); a longer name must fail here, not at insert.
    |> validate_length(:full_name, max: 255)
    |> validate_timezone()
  end

  @doc """
  The username, apart from the other basic fields so that only
  `Tymeslot.Profiles.change_username/2` (validation, rate limit, publish)
  can write it.
  """
  @spec username_changeset(t(), map()) :: Ecto.Changeset.t()
  def username_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:username])
    |> validate_username()
    |> unique_constraint(:username)
  end

  @doc "The stored avatar file name, or `nil` to remove it."
  @spec avatar_changeset(t(), map()) :: Ecto.Changeset.t()
  def avatar_changeset(profile, attrs), do: cast(profile, attrs, [:avatar])

  @doc """
  The name and avatar together, for an account provisioned with both at once.
  """
  @spec identity_changeset(t(), map()) :: Ecto.Changeset.t()
  def identity_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:full_name, :avatar])
    |> validate_length(:full_name, max: 255)
  end

  @doc "The booking page theme and whether it carries a customisation."
  @spec theme_changeset(t(), map()) :: Ecto.Changeset.t()
  def theme_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:booking_theme, :has_custom_theme])
    |> validate_booking_theme()
  end

  @doc "The sites allowed to embed the booking page."
  @spec embed_domains_changeset(t(), map()) :: Ecto.Changeset.t()
  def embed_domains_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:allowed_embed_domains])
    |> validate_embed_domains()
  end

  @doc "The calendar integration bookings are written to by default."
  @spec primary_calendar_changeset(t(), map()) :: Ecto.Changeset.t()
  def primary_calendar_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:primary_calendar_integration_id])
    |> foreign_key_constraint(:primary_calendar_integration_id)
  end

  @doc "The account-wide caps on bookings per day, week and month."
  @spec booking_limits_changeset(t(), map()) :: Ecto.Changeset.t()
  def booking_limits_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:max_bookings_per_day, :max_bookings_per_week, :max_bookings_per_month])
    |> validate_booking_limits(:profiles)
  end

  @doc """
  Focused changeset for setting or clearing the free/busy feed token, without
  re-validating unrelated fields. A `nil` token disables the feed.
  """
  @spec freebusy_token_changeset(t(), map()) :: Ecto.Changeset.t()
  def freebusy_token_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:freebusy_token])
    |> Token.put_hash(:freebusy_token, :freebusy_token_hash)
    |> unique_constraint(:freebusy_token_hash)
  end

  @booking_text_fields [:booking_heading, :booking_greeting, :booking_instruction]

  @doc """
  Focused changeset for the booking page's introductory text.

  The three strings are kept whether or not they are in use, so switching the
  customisation off and back on restores the organiser's wording instead of
  losing it. That is why the heading is required only while
  `booking_text_enabled` is true: a blank heading is an error when the text is
  live and unremarkable when it is not. The greeting and the instruction are
  never required; with the customisation on, a blank one is stored as `nil`
  and the page shows nothing for it.

  Casts with `empty_values: []` deliberately. Ecto's default treats `""` as
  absent, which would silently drop the change when an organiser clears a field,
  leaving the old wording on the page.
  """
  # Also applied to `Tymeslot.BookingPages.BookingPageSchema`, which carries
  # the same three fields and switch, so a page's texts follow the same rules.
  @spec booking_text_changeset(t() | struct(), map()) :: Ecto.Changeset.t()
  def booking_text_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:booking_text_enabled | @booking_text_fields], empty_values: [])
    |> update_booking_text()
    |> validate_length(:booking_heading, max: Constraints.booking_heading_max_length())
    |> validate_length(:booking_greeting, max: Constraints.booking_welcome_line_max_length())
    |> validate_length(:booking_instruction, max: Constraints.booking_welcome_line_max_length())
    |> validate_booking_text_present()
  end

  defp update_booking_text(changeset) do
    Enum.reduce(@booking_text_fields, changeset, fn field, acc ->
      update_change(acc, field, &normalize_text/1)
    end)
  end

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    # Postgres rejects null bytes even though they are valid UTF-8, so they are
    # stripped at the boundary rather than left to blow up on insert.
    trimmed =
      value
      |> String.replace("\x00", "")
      |> String.trim()

    blank_to_nil(trimmed)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Only the heading is required: a theme's voice may leave the greeting or the
  # instruction unsaid (Paper greets nobody, Folio gives no instruction), so an
  # organiser may too, and a blank line is dropped from the page.
  defp validate_booking_text_present(changeset) do
    if fetch_field!(changeset, :booking_text_enabled) do
      validate_required(changeset, [:booking_heading])
    else
      changeset
    end
  end

  @intro_fields [:headline, :bio]

  @doc """
  Focused changeset for the organiser's introduction: the one-line `headline`
  and the plain-text `bio` a theme may show on the booking page
  (`TymeslotWeb.Themes.Shared.Components.ProfileIntro`).

  Both are trimmed and stored as `nil` when blank, so clearing a field removes
  it from the page. Null bytes are stripped, as Postgres rejects them. A
  headline is one line, so any line break in it becomes a space; the bio's line
  breaks are its only formatting, so they are kept, normalised to `\\n`. The
  caps count characters after that clean-up.

  Casts with `empty_values: []` for the reason `booking_text_changeset/2`
  gives: a cleared field has to reach `normalize_text/1` to become `nil`.
  """
  @spec intro_changeset(t(), map()) :: Ecto.Changeset.t()
  def intro_changeset(profile, attrs) do
    profile
    |> cast(attrs, @intro_fields, empty_values: [])
    |> update_change(:headline, &normalize_headline/1)
    |> update_change(:bio, &normalize_bio/1)
    |> validate_length(:headline, max: Constraints.profile_headline_max_length())
    |> validate_length(:bio, max: Constraints.profile_bio_max_length())
  end

  defp normalize_headline(value) when is_binary(value),
    do: value |> String.replace(~r/[\r\n]+/, " ") |> normalize_text()

  defp normalize_headline(nil), do: nil

  defp normalize_bio(value) when is_binary(value),
    do: value |> String.replace(~r/\r\n?/, "\n") |> normalize_text()

  defp normalize_bio(nil), do: nil

  @legal_link_fields [:legal_notice_url, :privacy_policy_url]

  @doc """
  Focused changeset for the organiser's own legal links: the `legal_notice_url`
  (imprint) and the `privacy_policy_url` a booking page may link to.

  Each is trimmed and stored as `nil` when blank, so clearing a field removes
  the link. Null bytes are stripped, as Postgres rejects them. A link must be
  an http(s) URL of at most the shared URL length; https is required for a
  public host, while a private or local host may use http, and so may an
  intranet name such as `wiki.lan` or `intranet`: the links are never fetched,
  so the name's shape is all that needs trusting.

  Casts with `empty_values: []` for the reason `booking_text_changeset/2`
  gives: a cleared field has to reach `normalize_text/1` to become `nil`.
  """
  @spec legal_links_changeset(t(), map()) :: Ecto.Changeset.t()
  def legal_links_changeset(profile, attrs) do
    changeset = cast(profile, attrs, @legal_link_fields, empty_values: [])

    Enum.reduce(@legal_link_fields, changeset, fn field, acc ->
      acc
      |> update_change(field, &normalize_text/1)
      |> URLValidator.validate_url(field,
        enforce_https_for_public: true,
        internal_names_local: true
      )
    end)
  end

  @doc """
  Focused changeset for the booking languages: `content_locale` (the
  language the organiser's texts are written in; left unset, the one they
  read as until now, `Languages.original/1`, is saved), `translation_locales`
  and `offer_all_locales`.

  Every code must be a supported locale, a translation language may not be
  the original, and none may be listed twice. Removing a translation language
  leaves its stored texts in `translations`, so adding it again restores them.
  """
  @spec booking_languages_changeset(t(), map()) :: Ecto.Changeset.t()
  def booking_languages_changeset(profile, attrs) do
    supported = Locales.supported_codes()

    profile
    |> cast(attrs, [:content_locale, :translation_locales, :offer_all_locales])
    |> pin_original(profile)
    |> validate_inclusion(:content_locale, supported,
      message: dgettext_noop("errors", "is not a supported language")
    )
    |> validate_required([:content_locale, :offer_all_locales])
    |> validate_translation_locales(supported)
  end

  # An unset original is the booking pages' fallback, which an admin can
  # move onto one of the translation languages. Saved, it is the language the
  # texts have been read as until now, and no longer follows the fallback.
  defp pin_original(changeset, profile) do
    if get_field(changeset, :content_locale),
      do: changeset,
      else: put_change(changeset, :content_locale, Languages.original(profile))
  end

  defp validate_translation_locales(changeset, supported) do
    original = get_field(changeset, :content_locale)
    codes = get_field(changeset, :translation_locales) || []

    cond do
      Enum.any?(codes, &(&1 not in supported)) ->
        add_error(
          changeset,
          :translation_locales,
          dgettext_noop("errors", "is not a supported language")
        )

      original in codes ->
        add_error(
          changeset,
          :translation_locales,
          dgettext_noop("errors", "cannot include the original language")
        )

      Enum.uniq(codes) != codes ->
        add_error(
          changeset,
          :translation_locales,
          dgettext_noop("errors", "cannot list a language twice")
        )

      true ->
        changeset
    end
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
        if ReservedPaths.reserved?(username) do
          add_error(changeset, :username, "is reserved", validation: :reserved)
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
          add_error(changeset, :timezone, dgettext_noop("errors", "is not a valid timezone"))
        end
    end
  end

  defp validate_booking_theme(changeset) do
    valid_theme_ids = Catalog.valid_ids()

    validate_inclusion(changeset, :booking_theme, valid_theme_ids,
      message: dgettext_noop("errors", "must be a valid theme")
    )
  end

  # Entries the domain validator used to accept and no longer does. One
  # already saved is dropped when the host next changes the list, rather than
  # failing a list they did not type it into; typed afresh it is still refused.
  # `::1` never worked: a CSP host source cannot express an IPv6 literal.
  @retired_embed_domains ["::1"]

  defp validate_embed_domains(changeset) do
    case get_change(changeset, :allowed_embed_domains) do
      nil ->
        changeset

      domains when is_list(domains) ->
        stored = changeset.data.allowed_embed_domains || []
        domains = Enum.reject(domains, &(&1 in @retired_embed_domains and &1 in stored))
        max_domains = 20

        if length(domains) > max_domains do
          add_error(
            changeset,
            :allowed_embed_domains,
            dgettext("errors", "cannot have more than %{max} domains (currently %{current})",
              max: max_domains,
              current: length(domains)
            )
          )
        else
          case Security.validate_domains(domains) do
            {:ok, validated} ->
              put_change(changeset, :allowed_embed_domains, Enum.uniq(validated))

            {:error, messages} ->
              # add_error/3 prepends, so add them last first to keep their order.
              messages
              |> Enum.reverse()
              |> Enum.reduce(changeset, &add_error(&2, :allowed_embed_domains, &1))
          end
        end

      _other ->
        add_error(
          changeset,
          :allowed_embed_domains,
          dgettext_noop("errors", "must be a list of domains")
        )
    end
  end

  # Removed redundant validation functions in favor of Tymeslot.Security.Security.validate_domain/1
end
