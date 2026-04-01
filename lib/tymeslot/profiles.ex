defmodule Tymeslot.Profiles do
  @moduledoc """
  Context module for managing user profiles and settings.
  Acts as a coordination layer, providing a unified API while delegating
  specialized tasks to subcomponents.
  """

  alias Ecto.Changeset
  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.DatabaseSchemas.ProfileSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles.Avatars
  alias Tymeslot.Profiles.ReservedPaths
  alias Tymeslot.Profiles.Scheduling
  alias Tymeslot.Profiles.Timezone
  alias Tymeslot.Profiles.Usernames
  alias Tymeslot.Security.FieldValidators.UsernameValidator
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.Security
  alias Tymeslot.Themes.Theme
  alias Tymeslot.Validation.Constraints

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
  Gets a profile by its database ID.
  """
  @spec get_profile_by_id(integer()) :: profile | nil
  def get_profile_by_id(profile_id), do: ProfileQueries.get_with_user(profile_id)

  @doc """
  Gets or creates a profile for a user.
  """
  @spec get_or_create_profile(user_id) :: result(profile)
  def get_or_create_profile(user_id), do: ProfileQueries.get_or_create_by_user_id(user_id)

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

  # --- Profile Updates ---

  @doc """
  Updates a user's profile settings.
  """
  @spec update_profile(profile, map()) :: result(profile)
  def update_profile(%ProfileSchema{} = profile, attrs),
    do: ProfileQueries.update_profile(profile, attrs)

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
      {:ok, updated_profile}
    else
      {:error, :rate_limited} ->
        {:error, "Too many username change attempts. Please try again later."}

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

  @spec update_buffer_minutes(profile, non_neg_integer()) :: result(profile)
  def update_buffer_minutes(profile, buffer),
    do: Scheduling.update_buffer_minutes(profile, buffer)

  @spec update_advance_booking_days(profile, non_neg_integer()) :: result(profile)
  def update_advance_booking_days(profile, days),
    do: Scheduling.update_advance_booking_days(profile, days)

  @spec update_min_advance_hours(profile, non_neg_integer()) :: result(profile)
  def update_min_advance_hours(profile, hours),
    do: Scheduling.update_min_advance_hours(profile, hours)

  @doc """
  Validates buffer minutes value.
  """
  @spec validate_buffer_minutes(integer()) :: boolean()
  def validate_buffer_minutes(minutes),
    do: minutes in Constraints.buffer_minutes_range()

  @doc """
  Validates advance booking days value.
  """
  @spec validate_advance_booking_days(integer()) :: boolean()
  def validate_advance_booking_days(days),
    do: days in Constraints.advance_booking_days_range()

  @doc """
  Validates minimum advance hours value.
  """
  @spec validate_min_advance_hours(integer()) :: boolean()
  def validate_min_advance_hours(hours),
    do: hours in Constraints.min_advance_hours_range()

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

    case validate_avatar_upload(uploaded_entry) do
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

  defp validate_avatar_upload(file_params) do
    with :ok <- validate_avatar_file_type(file_params),
         :ok <- validate_avatar_file_size(file_params),
         :ok <- validate_avatar_file_name(file_params) do
      {:ok, file_params}
    end
  end

  defp validate_avatar_file_type(file_params) do
    case Map.get(file_params, "client_name") do
      nil ->
        {:error, "No file name provided"}

      filename ->
        extension = filename |> Path.extname() |> String.downcase()

        if extension in Avatars.accepted_extensions() do
          :ok
        else
          {:error, "Invalid file type. Only JPG, PNG, GIF, and WebP files are allowed"}
        end
    end
  end

  defp validate_avatar_file_size(file_params) do
    case Map.get(file_params, "size") do
      nil ->
        :ok

      size when is_integer(size) ->
        if size <= Avatars.max_file_size(),
          do: :ok,
          else: {:error, "File too large. Maximum size is 10MB"}

      _other ->
        {:error, "Invalid file size"}
    end
  end

  defp validate_avatar_file_name(file_params) do
    case Map.get(file_params, "client_name") do
      nil ->
        {:error, "No file name provided"}

      filename ->
        cond do
          String.contains?(filename, ["../", "..\\", "\0"]) ->
            {:error, "Invalid file name"}

          String.match?(filename, ~r/[<>:"\\|?*]/) ->
            {:error, "Invalid file name"}

          String.length(filename) > 255 ->
            {:error, "File name too long"}

          true ->
            :ok
        end
    end
  end

  @spec update_avatar(profile, uploaded_entry) :: result(profile)
  def update_avatar(profile, entry), do: Avatars.update_avatar(profile, entry)

  @spec delete_avatar(profile) :: result(profile)
  def delete_avatar(profile), do: Avatars.delete_avatar(profile)

  @spec avatar_url(profile | nil, atom()) :: String.t()
  def avatar_url(profile, version \\ :original), do: Avatars.avatar_url(profile, version)

  @spec avatar_alt_text(profile | nil) :: String.t()
  def avatar_alt_text(profile), do: Avatars.avatar_alt_text(profile)

  @doc """
  Gets a display name for greeting text.
  """
  @spec display_name(profile | nil) :: String.t() | nil
  def display_name(nil), do: nil

  def display_name(profile) do
    cond do
      profile.full_name && String.trim(profile.full_name) != "" ->
        profile.full_name

      (name = user_name(profile)) && String.trim(name) != "" ->
        name

      true ->
        nil
    end
  end

  defp user_name(%{user: %{name: name}}) when is_binary(name), do: name
  defp user_name(_profile), do: nil

  # --- Theme & Embed Settings ---

  @doc """
  Updates the booking theme for a profile with validation.
  """
  @spec update_booking_theme(profile, term()) :: result(profile)
  def update_booking_theme(%ProfileSchema{} = profile, theme_id) do
    if Theme.valid_theme_id?(theme_id),
      do: update_profile(profile, %{booking_theme: theme_id}),
      else: {:error, "Invalid theme ID"}
  end

  @doc """
  Parses a comma-separated domain string, deduplicates against the profile's
  existing whitelist, and returns the merged list ready for persistence.
  """
  @spec add_embed_domains(profile, String.t()) ::
          {:ok, [String.t()]} | {:error, :empty_input | {:duplicates, [String.t()]}}
  def add_embed_domains(%ProfileSchema{} = profile, domains_str) when is_binary(domains_str) do
    input_domains = parse_domain_input(domains_str)

    with :ok <- validate_non_empty_input(input_domains),
         :ok <- check_no_duplicates(input_domains, profile.allowed_embed_domains) do
      existing = normalize_existing_domains(profile.allowed_embed_domains)
      {:ok, existing ++ input_domains}
    end
  end

  defp parse_domain_input(str) do
    str
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp validate_non_empty_input([]), do: {:error, :empty_input}
  defp validate_non_empty_input(_domains), do: :ok

  defp check_no_duplicates(input_domains, existing_domains) do
    lowered_existing =
      existing_domains
      |> normalize_existing_domains()
      |> MapSet.new(&String.downcase/1)

    duplicates = Enum.filter(input_domains, &(String.downcase(&1) in lowered_existing))

    if duplicates == [],
      do: :ok,
      else: {:error, {:duplicates, duplicates}}
  end

  defp normalize_existing_domains(["none"]), do: []
  defp normalize_existing_domains(nil), do: []
  defp normalize_existing_domains(domains), do: domains

  @doc """
  Updates the allowed embed domains for a profile.
  """
  @spec update_allowed_embed_domains(profile, String.t() | [String.t()]) :: result(profile)
  def update_allowed_embed_domains(%ProfileSchema{} = profile, domains) when is_binary(domains) do
    domain_list =
      domains
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    # If the user explicitly cleared the field or entered "none", we treat it as disabled.
    # We allow "none" as a literal string here to support the "Disable" button flow.
    domain_list = if domain_list == [], do: ["none"], else: domain_list
    update_allowed_embed_domains(profile, domain_list)
  end

  def update_allowed_embed_domains(%ProfileSchema{} = profile, domains) when is_list(domains) do
    # If the only domain is "none", we skip normalization to preserve the keyword.
    if domains == ["none"] do
      update_profile(profile, %{allowed_embed_domains: ["none"]})
    else
      case Security.validate_domains(domains) do
        {:ok, validated} ->
          normalized = validated |> Enum.reject(&(&1 == "none")) |> Enum.uniq()
          update_profile(profile, %{allowed_embed_domains: normalized})

        {:error, error_msg} ->
          changeset =
            profile
            |> Changeset.change()
            |> Changeset.add_error(:allowed_embed_domains, error_msg)

          {:error, changeset}
      end
    end
  end

  # --- Organizer Context ---

  @doc """
  Resolves organizer context from username, including profile and meeting types.
  """
  @spec resolve_organizer_context(username) :: {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context(username) when is_binary(username) do
    case ProfileQueries.get_by_username_with_context(username) do
      {:ok, profile} -> {:ok, build_organizer_context(profile, username)}
      {:error, :not_found} -> {:error, :profile_not_found}
    end
  end

  @doc """
  Optimized version of resolve_organizer_context.
  """
  @spec resolve_organizer_context_optimized(username) ::
          {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context_optimized(username), do: resolve_organizer_context(username)

  defp build_organizer_context(profile, username) do
    meeting_types = meeting_types_for_profile(profile)
    display_name = profile.full_name || get_user_name_from_profile(profile) || username

    %{
      username: username,
      profile: profile,
      user_id: profile.user_id,
      meeting_types: meeting_types,
      page_title: "Schedule with #{display_name}"
    }
  end

  defp get_user_name_from_profile(%{user: %{name: name}}), do: name
  defp get_user_name_from_profile(_arg), do: nil

  defp meeting_types_for_profile(%{meeting_types: meeting_types, user_id: user_id}) do
    if is_list(meeting_types) and meeting_types != [] do
      meeting_types
    else
      if user_id, do: MeetingTypes.get_active_meeting_types(user_id), else: []
    end
  end
end
