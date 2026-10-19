defmodule Tymeslot.Profiles do
  @moduledoc """
  Context module for managing user profiles and settings.
  Acts as a coordination layer, providing a unified API while delegating
  specialized tasks to subcomponents.
  """

  @behaviour Tymeslot.Security.EncryptedStorage

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Availability
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles.Avatars
  alias Tymeslot.Profiles.EmbedDomains
  alias Tymeslot.Profiles.OrganizerContext
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Profiles.ReservedPaths
  alias Tymeslot.Profiles.Scheduling
  alias Tymeslot.Profiles.Timezone
  alias Tymeslot.Profiles.Usernames
  alias Tymeslot.Repo
  alias Tymeslot.Security.EncryptedString
  alias Tymeslot.Security.FieldValidators.UsernameValidator
  alias Tymeslot.Themes.Catalog
  alias Tymeslot.Timezones

  @type user_id :: pos_integer()
  @type username :: String.t()
  @type timezone :: String.t()
  @type profile :: ProfileSchema.t()
  @type error_reason :: atom() | String.t() | Ecto.Changeset.t()
  @type result(t) :: {:ok, t} | {:error, error_reason}
  @type uploaded_entry :: map()
  @type profile_settings :: %{
          timezone: timezone,
          max_bookings_per_day: pos_integer() | nil,
          max_bookings_per_week: pos_integer() | nil,
          max_bookings_per_month: pos_integer() | nil
        }

  # The free/busy feed token.
  @impl Tymeslot.Security.EncryptedStorage
  def encrypted_storage,
    do: {ProfileSchema.__schema__(:source), EncryptedString.columns(ProfileSchema)}

  # --- Profile Retrieval ---

  @doc """
  Gets a profile for a user.
  """
  @spec get_profile(user_id) :: profile | nil
  def get_profile(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, profile} -> profile
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Gets a profile for a user, returning a tagged result tuple.
  """
  @spec get_profile_by_user_id(user_id) :: result(profile)
  def get_profile_by_user_id(user_id), do: ProfileQueries.get_by_user_id(user_id)

  @doc """
  Gets a profile by its database ID.
  """
  @spec get_profile_by_id(integer()) :: profile | nil
  def get_profile_by_id(profile_id), do: ProfileQueries.get_with_user(profile_id)

  @doc """
  Gets or creates a profile for a user.
  Creates default weekly schedule for newly created profiles.

  Safe to call concurrently for the same user: whichever call loses the race
  to insert returns the winner's profile. Returns `{:error, :user_not_found}`
  when the user no longer exists.
  """
  @spec get_or_create_profile(user_id) :: result(profile) | {:error, :user_not_found}
  def get_or_create_profile(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, profile} ->
        {:ok, profile}

      {:error, :not_found} ->
        create_profile(user_id)
    end
  end

  @doc """
  Creates a profile for a user with its default weekly schedule and the
  default meeting types, which are seeded here, once.

  A profile created concurrently for the same user is returned as if this
  call had created it; a user deleted meanwhile gives
  `{:error, :user_not_found}`.
  """
  @spec create_profile(user_id) :: result(profile) | {:error, :user_not_found}
  def create_profile(user_id) do
    result =
      Repo.transaction(fn ->
        with {:ok, profile} <- ProfileQueries.insert_profile(user_id),
             {:ok, _schedule} <- Schedules.create_default(profile.id) do
          :ok = MeetingTypes.seed_default_meeting_types(user_id)
          profile
        else
          {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
          {:error, _reason} -> Repo.rollback(:failed_to_create_schedule)
        end
      end)

    settle_insert_race(result, user_id)
  end

  defp settle_insert_race({:error, %Ecto.Changeset{errors: errors}} = error, user_id) do
    case errors[:user_id] do
      {_message, opts} -> user_id_refusal(opts[:constraint], user_id, error)
      nil -> error
    end
  end

  defp settle_insert_race(result, _user_id), do: result

  defp user_id_refusal(:unique, user_id, _error), do: ProfileQueries.get_by_user_id(user_id)
  defp user_id_refusal(:foreign, _user_id, _error), do: {:error, :user_not_found}
  defp user_id_refusal(_other, _user_id, error), do: error

  @doc """
  Gets a profile by username.
  """
  @spec get_profile_by_username(username) :: profile | nil
  def get_profile_by_username(username) do
    case ProfileQueries.get_by_username(username) do
      {:ok, profile} -> profile
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Marks a host's booking page as published the first time it goes live.

  A page is "published" once the host has a username set. The write is guarded
  by `booking_page_published_at` so it happens at most once per host:

    * no username (nil or "") → `{:ok, :noop}`
    * already published → `{:ok, :noop}`
    * otherwise stamp the timestamp atomically → `{:ok, :published}`

  Returns `{:ok, :published}` only on the transition, so callers can use it to
  guard once-per-host side effects (e.g. analytics emission).
  """
  @spec mark_booking_page_published(profile()) :: {:ok, :published | :noop}
  def mark_booking_page_published(%ProfileSchema{username: username})
      when is_nil(username) or username == "",
      do: {:ok, :noop}

  def mark_booking_page_published(%ProfileSchema{booking_page_published_at: %DateTime{}}),
    do: {:ok, :noop}

  def mark_booking_page_published(%ProfileSchema{id: profile_id}) do
    published_at = DateTime.utc_now(:second)

    case ProfileQueries.mark_booking_page_published(profile_id, published_at) do
      1 -> {:ok, :published}
      0 -> {:ok, :noop}
    end
  end

  # --- Profile Updates ---

  @doc """
  Updates the host's name and time zone together, as the onboarding form
  submits them. The username is written by `change_username/2` alone.
  """
  @spec update_basic_details(profile, map()) :: result(profile)
  def update_basic_details(%ProfileSchema{} = profile, attrs),
    do: profile |> ProfileQueries.update_basic(attrs) |> changed()

  @doc """
  Sets the name and avatar of an account provisioned with both at once.
  """
  @spec provision_identity(profile, %{full_name: String.t(), avatar: String.t() | nil}) ::
          result(profile)
  def provision_identity(%ProfileSchema{} = profile, attrs),
    do: ProfileQueries.update_identity(profile, attrs)

  @doc """
  Records whether the profile's booking page carries a theme customisation.
  """
  @spec set_custom_theme(profile, boolean()) :: result(profile)
  def set_custom_theme(%ProfileSchema{} = profile, custom?) when is_boolean(custom?),
    do: ProfileQueries.update_theme(profile, %{has_custom_theme: custom?})

  # The booking page lays the host's hours out in their time zone and hides a
  # slot past their booking limits, so either change refreshes what it offers.
  defp changed({:ok, profile} = result) do
    Availability.changed(profile)
    result
  end

  defp changed(error), do: error

  @doc """
  Updates the booking page's introductory text and its on/off switch.
  """
  @spec update_booking_text(profile, map()) :: result(profile)
  def update_booking_text(%ProfileSchema{} = profile, attrs),
    do: ProfileQueries.update_booking_text(profile, attrs)

  @doc """
  Updates the organiser's headline and bio, the introduction a theme may show
  on the booking page. Callers sanitise the params first
  (`Tymeslot.Profiles.InputValidation.validate_intro/2`); the changeset owns
  the caps and the clean-up.
  """
  @spec update_intro(profile, map()) :: result(profile)
  def update_intro(%ProfileSchema{} = profile, attrs),
    do: ProfileQueries.update_intro(profile, attrs)

  @doc """
  Updates the full name for a profile.
  """
  @spec update_full_name(profile, String.t()) :: result(profile)
  def update_full_name(%ProfileSchema{} = profile, full_name),
    do: ProfileQueries.update_basic(profile, %{full_name: full_name})

  # --- Timezone Management ---

  @doc """
  Prefills the timezone for a profile based on a detected timezone.
  """
  @spec prefill_timezone(profile() | nil, String.t() | nil) :: profile() | nil
  def prefill_timezone(nil, _detected_timezone), do: nil

  def prefill_timezone(profile, detected_timezone) do
    prefilled_tz = Timezone.prefill_timezone(profile.timezone, detected_timezone)
    %{profile | timezone: prefilled_tz}
  end

  @doc """
  Gives a profile with no timezone one, persisted: the detected (browser)
  timezone when it is a real zone, otherwise the business default.

  A timezone the profile already has is never overwritten. Always returns
  `{:ok, profile}`: if the write fails, the profile comes back exactly as
  loaded, so a caller never holds a timezone that was not saved.
  """
  @spec ensure_timezone(profile(), String.t() | nil) :: {:ok, profile()}
  def ensure_timezone(%ProfileSchema{} = profile, detected_timezone) do
    case Timezone.prefill_timezone(profile.timezone, detected_timezone) do
      unchanged when unchanged == profile.timezone ->
        {:ok, profile}

      timezone ->
        case update_timezone(profile, timezone) do
          {:ok, updated} ->
            {:ok, updated}

          {:error, reason} ->
            Logger.warning("Could not persist a prefilled profile timezone",
              profile_id: profile.id,
              reason: LogFormat.reason(reason)
            )

            {:ok, profile}
        end
    end
  end

  @doc """
  Gets the timezone for a user, returning the default if no profile exists.
  """
  @spec get_user_timezone(user_id) :: timezone
  def get_user_timezone(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:error, :not_found} -> get_default_timezone()
      {:ok, profile} -> timezone(profile)
    end
  end

  @doc """
  A profile's timezone, or the default for a profile that has none set.

  `profiles.timezone` is nullable, so this is the one rule for reading an
  owner's clock: the booking page, time off, the free/busy feed and booking
  limits all go through it, and so agree on where a nil-timezone host's day
  begins. Takes anything carrying `:timezone`, or `nil` for no profile.

  A blank zone, or one the time-zone database does not know
  (`Timezones.valid?/1`), counts as none: every caller can shift into
  whatever this returns.
  """
  @spec timezone(map() | nil) :: timezone
  def timezone(%{timezone: timezone}) when is_binary(timezone) do
    if Timezones.valid?(timezone), do: timezone, else: get_default_timezone()
  end

  def timezone(_profile), do: get_default_timezone()

  @doc """
  Gets the default timezone.
  """
  @spec get_default_timezone() :: timezone
  def get_default_timezone, do: "Europe/Tallinn"

  @doc """
  Updates the timezone for a profile.
  """
  @spec update_timezone(profile, timezone) :: result(profile)
  def update_timezone(%ProfileSchema{} = profile, timezone),
    do: profile |> ProfileQueries.update_basic(%{timezone: timezone}) |> changed()

  # --- Username Management ---

  @doc """
  Generates a unique default username for a user.
  """
  @spec generate_default_username(user_id) :: username
  def generate_default_username(user_id), do: Usernames.generate_default_username(user_id)

  @doc """
  Checks if a username is available.
  """
  @spec username_available?(username) :: boolean()
  def username_available?(username), do: ProfileQueries.username_available?(username)

  @doc """
  Whether `username` can become `profile`'s username, and if not, why.

  Surrounding whitespace is ignored. The profile's own current username is
  `:unchanged` and is never re-checked, so a handle chosen before its word was
  reserved keeps working. Otherwise the format is checked first, then the
  reserved list, then whether another profile already holds it. `profile` may
  be `nil` when there is no profile yet.

  The profile changeset enforces the same rules again on write, which is what
  settles a username taken between this check and the save.
  """
  @spec username_status(profile() | map() | nil, term()) ::
          :unchanged | :ok | {:invalid, String.t()} | :reserved | :taken
  def username_status(profile, username) when is_binary(username) do
    candidate = String.trim(username)

    if current_username?(profile, candidate),
      do: :unchanged,
      else: new_username_status(candidate)
  end

  def username_status(_profile, username), do: new_username_status(username)

  defp current_username?(%{username: current}, candidate) when is_binary(current),
    do: current == candidate

  defp current_username?(_profile, _candidate), do: false

  defp new_username_status(username) do
    with :ok <- username_format_status(username),
         :ok <- username_reserved_status(username) do
      if ProfileQueries.username_available?(username), do: :ok, else: :taken
    end
  end

  defp username_format_status(username) do
    case UsernameValidator.validate(username) do
      :ok -> :ok
      {:error, message} -> {:invalid, message}
    end
  end

  defp username_reserved_status(username) do
    if ReservedPaths.reserved?(username), do: :reserved, else: :ok
  end

  @doc """
  Why a profile changeset refused its username: `:taken` when another profile
  holds it, `:reserved` when it is on the reserved list, `nil` for anything
  else (a malformed username, or an error on another field).
  """
  @spec username_error(Ecto.Changeset.t()) :: :reserved | :taken | nil
  def username_error(%Ecto.Changeset{errors: errors}) do
    errors
    |> Keyword.get_values(:username)
    |> Enum.find_value(&username_error_kind/1)
  end

  defp username_error_kind({_message, opts}) do
    cond do
      opts[:constraint] == :unique -> :taken
      opts[:validation] == :reserved -> :reserved
      true -> nil
    end
  end

  @doc """
  Changes a profile's username: the one path every username write takes, so
  each is validated (format and the reserved list), rate limited and can
  publish the booking page (`Tymeslot.BookingPage.Publication`).

  Submitting the profile's current username writes nothing and costs nothing.
  A username refused by validation does not count towards the change rate
  limit; only an attempt that reaches the database does.
  """
  @spec change_username(profile(), username()) :: result(profile())
  defdelegate change_username(profile, username), to: Usernames, as: :change

  @doc """
  Gives a profile without a username the system default
  (`generate_default_username/1`), as when onboarding moves on without one.
  A profile that already has a username is returned unchanged.

  A system write: it is validated and can publish the booking page like any
  other username write, but is not counted against the user's change rate
  limit, so a user who spent their allowance still gets a resolvable page.
  `{:error, :not_found}` when the profile has been deleted since it was
  read.
  """
  @spec ensure_default_username(profile()) :: result(profile())
  defdelegate ensure_default_username(profile), to: Usernames, as: :ensure_default

  @doc """
  Returns a list of reserved paths.
  """
  @spec reserved_paths() :: [String.t()]
  def reserved_paths, do: ReservedPaths.list()

  # --- Scheduling Preferences ---

  @doc """
  Gets all profile settings for a user.
  """
  @spec get_profile_settings(user_id) :: profile_settings
  def get_profile_settings(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:error, :not_found} ->
        %{
          timezone: get_default_timezone(),
          max_bookings_per_day: nil,
          max_bookings_per_week: nil,
          max_bookings_per_month: nil
        }

      {:ok, profile} ->
        %{
          timezone: timezone(profile),
          max_bookings_per_day: profile.max_bookings_per_day,
          max_bookings_per_week: profile.max_bookings_per_week,
          max_bookings_per_month: profile.max_bookings_per_month
        }
    end
  end

  @spec update_booking_limit(profile, atom(), String.t() | integer() | nil) :: result(profile)
  def update_booking_limit(profile, field, value),
    do: Scheduling.update_booking_limit(profile, field, value)

  # --- Avatar Management ---

  @doc """
  Consumption callback for avatar upload.
  Validates the upload using security policies before updating the profile.
  """
  @spec consume_avatar_upload(profile(), map(), map(), map()) ::
          {:ok, profile() | {:error, any()}}
  def consume_avatar_upload(profile, %{path: path}, entry, _metadata) do
    uploaded_entry = %{
      "path" => path,
      "client_name" => entry.client_name,
      "size" => entry.client_size
    }

    case Avatars.validate_upload(uploaded_entry) do
      {:ok, validated_entry} ->
        atom_entry = %{path: validated_entry["path"], client_name: validated_entry["client_name"]}

        case Avatars.update_avatar(profile, atom_entry) do
          {:ok, updated_profile} -> {:ok, updated_profile}
          {:error, reason} -> {:ok, {:error, reason}}
        end

      {:error, validation_error} ->
        {:ok, {:error, validation_error}}
    end
  end

  @spec delete_avatar(profile) :: result(profile)
  def delete_avatar(profile), do: Avatars.delete_avatar(profile)

  @doc """
  Removes every avatar file stored for a deleted profile. See
  `Avatars.delete_all_files/1`.
  """
  @spec delete_avatar_files(pos_integer()) :: :ok | {:error, File.posix(), Path.t()}
  def delete_avatar_files(profile_id), do: Avatars.delete_all_files(profile_id)

  @spec avatar_url(profile | nil, atom()) :: String.t()
  def avatar_url(profile, version \\ :original), do: Avatars.avatar_url(profile, version)

  @doc """
  The generated fallback avatar as a data URI, for a profile or profile-shaped
  map without an uploaded image. See `Avatars.fallback_data_uri/2`.
  """
  @spec fallback_avatar_data_uri(map() | nil, non_neg_integer()) :: String.t()
  def fallback_avatar_data_uri(profile, size \\ 300), do: Avatars.fallback_data_uri(profile, size)

  @doc """
  Returns the public path to a profile's uploaded avatar image, or `nil` when
  none has been uploaded. Never returns a data URI (see `Avatars.uploaded_avatar_path/1`).
  """
  @spec uploaded_avatar_path(profile | nil) :: String.t() | nil
  def uploaded_avatar_path(profile), do: Avatars.uploaded_avatar_path(profile)

  @doc """
  Returns the absolute URL of a profile's uploaded avatar image, or `nil` when
  none has been uploaded (see `Avatars.uploaded_avatar_url/1`).
  """
  @spec uploaded_avatar_url(profile | nil) :: String.t() | nil
  def uploaded_avatar_url(profile), do: Avatars.uploaded_avatar_url(profile)

  @spec avatar_alt_text(profile | nil) :: String.t()
  def avatar_alt_text(profile), do: Avatars.avatar_alt_text(profile)

  @doc """
  Gets a display name for greeting text.

  The canonical precedence for "what do we call this person": the profile's
  `full_name` first, then the name captured at OAuth signup (only available
  when `:user` is preloaded), then `nil`. Never falls back to the email
  address.
  """
  @spec display_name(profile | nil) :: String.t() | nil
  def display_name(nil), do: nil

  def display_name(profile), do: presence(profile.full_name) || presence(user_name(profile))

  @doc """
  Gets a display name for greeting text, starting from the user side of the
  association.

  Same precedence as `display_name/1`, for callers that hold a user rather
  than a profile (the email templates, for instance). `:profile` must be
  preloaded: raises `ArgumentError` when it is an
  `Ecto.Association.NotLoaded` struct, since silently falling back to the
  user's own name is indistinguishable from an email/password signup that
  legitimately has none. Callers must fetch the user via a function that
  preloads `:profile`, such as `Auth.UserQueries.get_user_with_profile/1`.
  """
  @spec user_display_name(map() | nil) :: String.t() | nil
  def user_display_name(nil), do: nil

  def user_display_name(%{profile: %ProfileSchema{} = profile} = user),
    do: display_name(%{profile | user: user})

  def user_display_name(%{profile: %Ecto.Association.NotLoaded{}}) do
    raise ArgumentError, "user.profile must be preloaded; use get_user_with_profile/1"
  end

  def user_display_name(user), do: presence(user_name(%{user: user}))

  defp user_name(%{user: %{name: name}}) when is_binary(name), do: name
  defp user_name(_profile), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  # --- Theme & Embed Settings ---

  @doc """
  Updates the booking theme for a profile with validation.
  """
  @spec update_booking_theme(profile, term()) :: result(profile)
  def update_booking_theme(%ProfileSchema{} = profile, theme_id) do
    if Catalog.valid_id?(to_string(theme_id)),
      do: ProfileQueries.update_theme(profile, %{booking_theme: theme_id}),
      else: {:error, "Invalid theme ID"}
  end

  @doc """
  Parses a comma-separated domain string, deduplicates against the profile's
  existing whitelist, and returns the merged list ready for persistence.
  """
  @spec add_embed_domains(profile, String.t()) ::
          {:ok, [String.t()]} | {:error, :empty_input | {:duplicates, [String.t()]}}
  def add_embed_domains(%ProfileSchema{} = profile, domains_str),
    do: EmbedDomains.add_embed_domains(profile, domains_str)

  @doc """
  Updates the allowed embed domains for a profile.
  """
  @spec update_allowed_embed_domains(profile, String.t() | [String.t()]) :: result(profile)
  def update_allowed_embed_domains(%ProfileSchema{} = profile, domains),
    do: ProfileQueries.update_embed_domains(profile, EmbedDomains.normalize(domains))

  # --- Organizer Context ---

  @doc """
  Resolves organizer context from username, including profile and meeting types.
  """
  @spec resolve_organizer_context(username) :: {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context(username),
    do: OrganizerContext.resolve_organizer_context(username)
end
