defmodule Tymeslot.Profiles do
  @moduledoc """
  Context module for managing user profiles and settings.
  """

  alias Tymeslot.Bookings.Validation
  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.DatabaseSchemas.ProfileSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Security.FormValidation
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Themes.Theme
  alias Tymeslot.Utils.AvatarUtils
  alias TymeslotWeb.Helpers.UploadHandler

  @type user_id :: pos_integer()
  @type username :: String.t()
  @type timezone :: String.t()
  @type profile :: ProfileSchema.t()
  @type error_reason :: atom() | String.t() | Ecto.Changeset.t()
  @type result(t) :: {:ok, t} | {:error, error_reason}
  @type uploaded_entry :: map()
  @type profile_settings :: %{
          timezone: timezone,
          buffer_minutes: non_neg_integer(),
          advance_booking_days: non_neg_integer(),
          min_advance_hours: non_neg_integer()
        }

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
  Gets or creates a profile for a user.
  """
  @spec get_or_create_profile(user_id) :: result(profile)
  def get_or_create_profile(user_id) do
    ProfileQueries.get_or_create_by_user_id(user_id)
  end

  @doc """
  Updates a user's profile settings.
  """
  @spec update_profile(profile, map()) :: result(profile)
  def update_profile(%ProfileSchema{} = profile, attrs) do
    ProfileQueries.update_profile(profile, attrs)
  end

  @doc """
  Updates a specific field in the profile.
  """
  @spec update_profile_field(profile, atom(), term()) :: result(profile)
  def update_profile_field(%ProfileSchema{} = profile, field, value) do
    ProfileQueries.update_field(profile, field, value)
  end

  @doc """
  Gets the timezone for a user, returning the default if no profile exists.
  """
  @spec get_user_timezone(user_id) :: timezone
  def get_user_timezone(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:error, :not_found} -> get_default_timezone()
      {:ok, profile} -> profile.timezone
    end
  end

  @doc """
  Gets the default timezone.
  """
  @spec get_default_timezone() :: timezone
  def get_default_timezone do
    "Europe/Kyiv"
  end

  @doc """
  Gets all profile settings for a user.
  """
  @spec get_profile_settings(user_id) :: profile_settings
  def get_profile_settings(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:error, :not_found} ->
        # Return default settings
        %{
          timezone: get_default_timezone(),
          buffer_minutes: 15,
          advance_booking_days: 90,
          min_advance_hours: 3
        }

      {:ok, profile} ->
        %{
          timezone: profile.timezone,
          buffer_minutes: profile.buffer_minutes,
          advance_booking_days: profile.advance_booking_days,
          min_advance_hours: profile.min_advance_hours
        }
    end
  end

  @doc """
  Updates the timezone for a profile with validation.
  """
  @spec update_timezone(profile, timezone) :: result(profile)
  def update_timezone(%ProfileSchema{} = profile, timezone) do
    update_profile(profile, %{timezone: timezone})
  end

  @doc """
  Updates the full name for a profile.
  """
  @spec update_full_name(profile, String.t()) :: result(profile)
  def update_full_name(%ProfileSchema{} = profile, full_name) do
    update_profile(profile, %{full_name: full_name})
  end

  @doc """
  Updates buffer minutes with validation.
  Valid range: 0-120 minutes.
  """
  @spec update_buffer_minutes(profile, String.t() | integer()) :: result(profile)
  def update_buffer_minutes(%ProfileSchema{} = profile, buffer_str) when is_binary(buffer_str) do
    case Integer.parse(buffer_str) do
      {buffer_minutes, _} ->
        update_buffer_minutes(profile, buffer_minutes)

      _ ->
        {:error, :invalid_buffer_minutes}
    end
  end

  def update_buffer_minutes(%ProfileSchema{} = profile, buffer_minutes)
      when is_integer(buffer_minutes) do
    if Validation.valid_buffer_minutes?(buffer_minutes) do
      update_profile(profile, %{buffer_minutes: buffer_minutes})
    else
      {:error, :invalid_buffer_minutes}
    end
  end

  @doc """
  Updates advance booking days with validation.
  Valid range: 1-365 days.
  """
  @spec update_advance_booking_days(profile, String.t() | integer()) :: result(profile)
  def update_advance_booking_days(%ProfileSchema{} = profile, days_str)
      when is_binary(days_str) do
    case Integer.parse(days_str) do
      {days, _} ->
        update_advance_booking_days(profile, days)

      _ ->
        {:error, :invalid_advance_booking_days}
    end
  end

  def update_advance_booking_days(%ProfileSchema{} = profile, days) when is_integer(days) do
    if Validation.valid_booking_window?(days) do
      update_profile(profile, %{advance_booking_days: days})
    else
      {:error, :invalid_advance_booking_days}
    end
  end

  @doc """
  Updates minimum advance hours with validation.
  Valid range: 0-168 hours (0-7 days).
  """
  @spec update_min_advance_hours(profile, String.t() | integer()) :: result(profile)
  def update_min_advance_hours(%ProfileSchema{} = profile, hours_str) when is_binary(hours_str) do
    case Integer.parse(hours_str) do
      {hours, _} when hours >= 0 and hours <= 168 ->
        update_profile(profile, %{min_advance_hours: hours})

      _ ->
        {:error, :invalid_min_advance_hours}
    end
  end

  def update_min_advance_hours(%ProfileSchema{} = profile, hours) when is_integer(hours) do
    if hours >= 0 and hours <= 168 do
      update_profile(profile, %{min_advance_hours: hours})
    else
      {:error, :invalid_min_advance_hours}
    end
  end

  @doc """
  Validates buffer minutes value.
  Delegates to pure validation module.
  """
  @spec validate_buffer_minutes(integer()) :: boolean()
  defdelegate validate_buffer_minutes(minutes), to: Validation, as: :valid_buffer_minutes?

  @doc """
  Validates advance booking days value.
  Delegates to pure validation module.
  """
  @spec validate_advance_booking_days(integer()) :: boolean()
  defdelegate validate_advance_booking_days(days), to: Validation, as: :valid_booking_window?

  @doc """
  Validates minimum advance hours value.
  Delegates to pure validation module.
  """
  @spec validate_min_advance_hours(integer()) :: boolean()
  defdelegate validate_min_advance_hours(hours), to: Validation, as: :valid_minimum_notice?

  @doc """
  Generates a unique default username for a user.
  """
  @spec generate_default_username(user_id) :: username
  def generate_default_username(user_id) do
    base = "user_#{user_id}"

    if username_available?(base) do
      base
    else
      generate_random_username(base, 3)
    end
  end

  defp generate_random_username(base, 0), do: "#{base}_#{random_suffix()}"

  defp generate_random_username(base, attempts) do
    candidate = "#{base}_#{random_suffix()}"

    if username_available?(candidate) do
      candidate
    else
      generate_random_username(base, attempts - 1)
    end
  end

  defp random_suffix do
    Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  @doc """
  Checks if a username is available.
  """
  @spec username_available?(username) :: boolean()
  def username_available?(username) do
    ProfileQueries.username_available?(username)
  end

  @doc """
  Updates a user's username with validation and rate limiting.
  """
  @spec update_username(profile(), username(), user_id()) :: result(profile())
  def update_username(%ProfileSchema{} = profile, username, user_id)
      when is_binary(username) and is_integer(user_id) do
    # Apply rate limiting
    with :ok <- check_username_rate_limit(user_id),
         # Validate input
         :ok <- validate_username_input(username),
         # Update in database
         {:ok, updated_profile} <- ProfileQueries.update_username(profile, username) do
      {:ok, updated_profile}
    else
      {:error, :rate_limited} ->
        {:error, "Too many username change attempts. Please try again later."}

      {:error, reason} ->
        {:error, reason}
    end
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
  Resolves organizer context from username, including profile and meeting types.
  Returns {:ok, context} or {:error, reason}.
  """
  @spec resolve_organizer_context(username) :: {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context(username) when is_binary(username) do
    result = ProfileQueries.get_by_username_with_context(username)

    case result do
      {:ok, profile} ->
        {:ok, build_organizer_context(profile, username)}

      {:error, :not_found} ->
        {:error, :profile_not_found}
    end
  end

  @doc """
  Optimized version of resolve_organizer_context that uses a single query.
  This replaces the previous 3-query approach with a single database call.
  """
  @spec resolve_organizer_context_optimized(username) ::
          {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context_optimized(username) when is_binary(username) do
    resolve_organizer_context(username)
  end

  @spec build_organizer_context(map(), username) :: map()
  defp build_organizer_context(profile, username) do
    meeting_types = meeting_types_for_profile(profile)

    %{
      username: username,
      profile: profile,
      user_id: profile.user_id,
      meeting_types: meeting_types,
      page_title: "Schedule with #{profile.full_name || profile.user.name || username}"
    }
  end

  @spec meeting_types_for_profile(%{meeting_types: any(), user_id: integer()}) :: list()
  defp meeting_types_for_profile(%{meeting_types: meeting_types, user_id: user_id}) do
    if is_list(meeting_types) and meeting_types != [] do
      meeting_types
    else
      MeetingTypes.get_active_meeting_types(user_id)
    end
  end

  # Checks username change rate limit.
  # 3 attempts per hour per user.
  defp check_username_rate_limit(user_id) when is_integer(user_id) do
    RateLimiter.check_username_change_rate_limit("user:" <> Integer.to_string(user_id))
  end

  defp validate_username_input(username) do
    with :ok <- FormValidation.validate_field(:username, username),
         :ok <- validate_username_format(username) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates username format without modifying it.
  Usernames must be 3-30 characters, lowercase letters, numbers, and hyphens only.
  Must start with a letter or number.
  """
  @spec validate_username_format(term()) :: :ok | {:error, String.t()}
  def validate_username_format(username) when is_binary(username) do
    cond do
      String.length(username) < 3 ->
        {:error, "Username must be at least 3 characters long"}

      String.length(username) > 30 ->
        {:error, "Username must be at most 30 characters long"}

      !Regex.match?(~r/^[a-z0-9][a-z0-9_-]{2,29}$/, username) ->
        {:error,
         "Username must contain only lowercase letters, numbers, underscores, and hyphens, and start with a letter or number"}

      username in reserved_usernames() ->
        {:error, "This username is reserved"}

      true ->
        :ok
    end
  end

  def validate_username_format(_), do: {:error, "Username must be a string"}

  defp reserved_usernames do
    [
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
  end

  @doc """
  Updates a user's avatar using the unified upload system.
  """
  @spec update_avatar(profile, uploaded_entry) :: result(profile)
  def update_avatar(%ProfileSchema{} = profile, uploaded_entry) do
    old_avatar = profile.avatar
    context = %{user_id: profile.id, operation: "avatar_update"}

    with {:ok, filename} <- store_avatar_file(uploaded_entry, profile),
         result <- ProfileQueries.update_avatar(profile, filename) do
      case result do
        {:ok, updated_profile} ->
          maybe_delete_old_avatar(old_avatar, profile, context)
          {:ok, updated_profile}

        {:error, reason} ->
          # Database update failed: cleanup newly uploaded file
          new_file_path = build_avatar_path(filename, profile)

          UploadHandler.delete_file_safely(
            new_file_path,
            Map.put(context, :file_type, "failed_upload")
          )

          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_delete_old_avatar(nil, _profile, _context), do: :ok

  defp maybe_delete_old_avatar(old_avatar, profile, context) do
    old_file_path = build_avatar_path(old_avatar, profile)
    UploadHandler.delete_file_safely(old_file_path, Map.put(context, :file_type, "old_avatar"))
  end

  @doc """
  Deletes a user's avatar.
  """
  @spec delete_avatar(profile) :: result(profile)
  def delete_avatar(%ProfileSchema{} = profile) do
    context = %{user_id: profile.id, operation: "avatar_delete"}

    # Delete database record first
    case ProfileQueries.remove_avatar(profile) do
      {:ok, updated_profile} ->
        # Then cleanup file if it exists
        if profile.avatar do
          file_path = build_avatar_path(profile.avatar, profile)
          UploadHandler.delete_file_safely(file_path, context)
        end

        {:ok, updated_profile}

      error ->
        error
    end
  end

  @doc """
  Gets the avatar URL for a profile, with fallback to default.
  """
  @spec avatar_url(profile | nil, atom()) :: String.t()
  def avatar_url(profile, _version \\ :original)

  def avatar_url(nil, _version) do
    # Return a default avatar URL when profile is nil
    AvatarUtils.generate_fallback_data_uri(nil)
  end

  def avatar_url(%ProfileSchema{} = profile, _version) do
    case profile.avatar do
      nil ->
        AvatarUtils.generate_fallback_data_uri(profile)

      "" ->
        AvatarUtils.generate_fallback_data_uri(profile)

      avatar ->
        # Check if the avatar is already a full path (starts with /)
        if String.starts_with?(avatar, "/") do
          # Use as-is for static paths
          avatar
        else
          # Prefix for uploaded files
          "/uploads/avatars/#{profile.id}/#{avatar}"
        end
    end
  end

  @doc """
  Gets appropriate alt text for the avatar image.

  ## Parameters
    - profile: A ProfileSchema struct or nil

  ## Returns
    A string to use as alt text for the avatar image
  """
  @spec avatar_alt_text(profile | nil) :: String.t()
  def avatar_alt_text(nil), do: "Profile"

  def avatar_alt_text(profile) do
    cond do
      profile.full_name && String.trim(profile.full_name) != "" ->
        profile.full_name

      profile.user && profile.user.email ->
        "Profile of #{profile.user.email}"

      true ->
        "Profile"
    end
  end

  @doc """
  Gets a display name for greeting text.

  ## Parameters
    - profile: A ProfileSchema struct or nil

  ## Returns
    The user's full name if available, nil otherwise
  """
  @spec display_name(profile | nil) :: String.t() | nil
  def display_name(nil), do: nil

  def display_name(profile) do
    if profile.full_name && String.trim(profile.full_name) != "" do
      profile.full_name
    else
      nil
    end
  end

  @doc """
  Updates the booking theme for a profile with validation.
  """
  @spec update_booking_theme(profile, term()) :: result(profile)
  def update_booking_theme(%ProfileSchema{} = profile, theme_id) do
    if Theme.valid_theme_id?(theme_id) do
      update_profile(profile, %{booking_theme: theme_id})
    else
      {:error, "Invalid theme ID"}
    end
  end

  # Private functions for file handling

  defp store_avatar_file(uploaded_entry, profile) do
    # Generate unique filename
    timestamp = System.system_time(:second)
    extension = String.downcase(Path.extname(uploaded_entry.client_name))
    filename = "#{profile.id}_avatar_#{timestamp}#{extension}"

    # Create directory structure - ensure all directories exist
    upload_dir = get_upload_directory()
    ensure_directory_exists(upload_dir)
    profile_dir = Path.join([upload_dir, "avatars", to_string(profile.id)])
    ensure_directory_exists(profile_dir)

    # Copy uploaded file to destination
    dest_path = Path.join(profile_dir, filename)

    case File.cp(uploaded_entry.path, dest_path) do
      :ok -> {:ok, filename}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_avatar_path(filename, profile) do
    upload_dir = get_upload_directory()
    Path.join([upload_dir, "avatars", to_string(profile.id), filename])
  end

  defp get_upload_directory do
    Application.get_env(:tymeslot, :upload_directory, "uploads")
  end

  defp ensure_directory_exists(dir_path) do
    case File.mkdir_p(dir_path) do
      :ok ->
        :ok

      {:error, :eacces} ->
        require Logger
        Logger.error("Permission denied creating directory: #{dir_path}")
        raise "Failed to create upload directory due to permissions: #{dir_path}"

      {:error, :enospc} ->
        require Logger
        Logger.error("No space left on device for directory: #{dir_path}")
        raise "No space left on device to create directory: #{dir_path}"

      {:error, reason} ->
        require Logger
        Logger.error("Failed to create directory #{dir_path}: #{reason}")
        raise "Failed to create upload directory: #{dir_path} (#{reason})"
    end
  end
end
