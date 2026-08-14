defmodule Tymeslot.Profiles do
  @moduledoc """
  Context module for managing user profiles and settings.
  Acts as a coordination layer, providing a unified API while delegating
  specialized tasks to subcomponents.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Availability.Schedules
  alias Tymeslot.BookingPage.Publication
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
  alias Tymeslot.Security.FieldValidators.UsernameValidator
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Themes.Catalog

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
  Assigns a system-generated default username to a profile, bypassing rate limiting.

  This is intended for system use only (e.g. assigning a username during onboarding
  completion when the user has not chosen one themselves).
  """
  @spec assign_default_username(profile(), username()) :: result(profile())
  def assign_default_username(%ProfileSchema{} = profile, username) do
    with {:ok, updated_profile} <- ProfileQueries.update_username(profile, username) do
      Publication.maybe_publish(updated_profile.user_id)
      {:ok, updated_profile}
    end
  end

  @doc """
  Gets a profile by its database ID.
  """
  @spec get_profile_by_id(integer()) :: profile | nil
  def get_profile_by_id(profile_id), do: ProfileQueries.get_with_user(profile_id)

  @doc """
  Gets or creates a profile for a user.
  Creates default weekly schedule for newly created profiles.
  """
  @spec get_or_create_profile(user_id) :: result(profile)
  def get_or_create_profile(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, profile} ->
        {:ok, profile}

      {:error, :not_found} ->
        create_profile(user_id)
    end
  end

  @doc """
  Creates a profile for a user with default weekly schedule.
  """
  @spec create_profile(user_id) :: result(profile)
  def create_profile(user_id) do
    Repo.transaction(fn ->
      with {:ok, profile} <- ProfileQueries.insert_profile(user_id),
           {:ok, _schedule} <- Schedules.create_default(profile.id) do
        profile
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
        {:error, _reason} -> Repo.rollback(:failed_to_create_schedule)
      end
    end)
  end

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
  Updates a user's profile settings.
  """
  @spec update_profile(profile, map()) :: result(profile)
  def update_profile(%ProfileSchema{} = profile, attrs) do
    case ProfileQueries.update_profile(profile, attrs) do
      {:ok, updated_profile} = result ->
        Logger.info("Profile updated successfully",
          user_id: updated_profile.user_id,
          timezone: updated_profile.timezone
        )

        result

      error ->
        error
    end
  end

  @doc """
  Updates a specific field in the profile.
  """
  @spec update_profile_field(profile, atom(), term()) :: result(profile)
  def update_profile_field(%ProfileSchema{} = profile, field, value),
    do: ProfileQueries.update_field(profile, field, value)

  @doc """
  Updates the full name for a profile.
  """
  @spec update_full_name(profile, String.t()) :: result(profile)
  def update_full_name(%ProfileSchema{} = profile, full_name),
    do: update_profile(profile, %{full_name: full_name})

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
  Gets the timezone for a user, returning the default if no profile exists.
  """
  @spec get_user_timezone(user_id) :: timezone
  def get_user_timezone(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:error, :not_found} -> get_default_timezone()
      {:ok, profile} -> profile.timezone || get_default_timezone()
    end
  end

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
    do: update_profile(profile, %{timezone: timezone})

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
  Updates a user's username with validation and rate limiting.
  """
  @spec update_username(profile(), username(), user_id()) :: result(profile())
  def update_username(%ProfileSchema{} = profile, username, user_id) do
    with :ok <-
           RateLimiter.check_username_change_rate_limit("user:" <> Integer.to_string(user_id)),
         :ok <- UsernameValidator.validate(username, reserved_words: ReservedPaths.list()),
         {:ok, updated_profile} <- ProfileQueries.update_username(profile, username) do
      Publication.maybe_publish(updated_profile.user_id)
      {:ok, updated_profile}
    else
      {:error, :rate_limited} ->
        {:error,
         dgettext(
           "dashboard_profile",
           "Too many username change attempts. Please try again later."
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validates username format.
  """
  @spec validate_username_format(term()) :: :ok | {:error, String.t()}
  def validate_username_format(username),
    do: UsernameValidator.validate(username, reserved_words: ReservedPaths.list())

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
          timezone: profile.timezone,
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

  @spec update_avatar(profile, uploaded_entry) :: result(profile)
  def update_avatar(profile, entry), do: Avatars.update_avatar(profile, entry)

  @spec delete_avatar(profile) :: result(profile)
  def delete_avatar(profile), do: Avatars.delete_avatar(profile)

  @spec avatar_url(profile | nil, atom()) :: String.t()
  def avatar_url(profile, version \\ :original), do: Avatars.avatar_url(profile, version)

  @doc """
  Returns the public path to a profile's uploaded avatar image, or `nil` when
  none has been uploaded. Never returns a data URI (see `Avatars.uploaded_avatar_path/1`).
  """
  @spec uploaded_avatar_path(profile | nil) :: String.t() | nil
  def uploaded_avatar_path(profile), do: Avatars.uploaded_avatar_path(profile)

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
      do: update_profile(profile, %{booking_theme: theme_id}),
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
  def update_allowed_embed_domains(%ProfileSchema{} = profile, domains) do
    with {:ok, attrs} <- EmbedDomains.validate_and_normalize(profile, domains) do
      update_profile(profile, attrs)
    end
  end

  # --- Organizer Context ---

  @doc """
  Resolves organizer context from username, including profile and meeting types.
  """
  @spec resolve_organizer_context(username) :: {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context(username),
    do: OrganizerContext.resolve_organizer_context(username)

  @doc """
  Optimized version of resolve_organizer_context.
  """
  @spec resolve_organizer_context_optimized(username) ::
          {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context_optimized(username), do: resolve_organizer_context(username)
end
