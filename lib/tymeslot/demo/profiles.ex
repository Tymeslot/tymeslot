defmodule Tymeslot.Demo.Profiles do
  @moduledoc """
  Demo implementation of the Profiles context.

  This module provides profile-related functions for demo users,
  returning hardcoded data instead of querying the database.
  """

  alias Tymeslot.DatabaseSchemas.ProfileSchema
  alias Tymeslot.Demo.Data
  alias Tymeslot.Utils.AvatarUtils

  @doc """
  Gets a demo profile by username.

  Mimics Tymeslot.Profiles.get_profile_by_username/1
  """
  @spec get_profile_by_username(String.t()) :: map() | nil
  def get_profile_by_username(username) when is_binary(username) do
    Data.get_demo_profile_by_username(username)
  end

  @doc """
  Resolves organizer context for a demo user.

  Mimics Tymeslot.Profiles.resolve_organizer_context/1
  """
  @spec resolve_organizer_context(String.t()) :: {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context(username) when is_binary(username) do
    case Data.get_demo_profile_by_username(username) do
      nil ->
        {:error, :profile_not_found}

      profile ->
        meeting_types = Data.get_demo_meeting_types(profile.user_id)

        context = %{
          username: profile.username,
          profile: profile,
          user_id: profile.user_id,
          meeting_types: meeting_types,
          page_title: "Schedule a meeting with #{profile.full_name}"
        }

        {:ok, context}
    end
  end

  @doc """
  Resolves organizer context optimized for demo users.

  Mimics Tymeslot.Profiles.resolve_organizer_context_optimized/1
  """
  @spec resolve_organizer_context_optimized(String.t()) ::
          {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context_optimized(username) do
    case resolve_organizer_context(username) do
      {:ok, context} -> {:ok, context}
      {:error, :profile_not_found} -> {:error, :profile_not_found}
    end
  end

  @doc """
  Gets profile with user association for demo users.
  """
  @spec get_profile_with_user(integer()) :: map() | nil
  def get_profile_with_user(profile_id) when is_integer(profile_id) do
    cond do
      profile_id == 999_001 -> Data.get_demo_profile("1")
      profile_id == 999_002 -> Data.get_demo_profile("2")
      true -> nil
    end
  end

  @doc """
  Gets profile by ID for demo users.
  """
  @spec get_profile(integer()) :: map() | nil
  def get_profile(profile_id) when is_integer(profile_id) do
    get_profile_with_user(profile_id)
  end

  @doc """
  Checks if a username exists (for demo users, always returns true for demo usernames).
  """
  @spec username_exists?(String.t()) :: boolean()
  def username_exists?(username) when is_binary(username) do
    String.starts_with?(username, "demo-theme-")
  end

  @doc """
  Updates profile settings (no-op for demo users).
  """
  @spec update_profile_settings(any(), any()) :: {:error, :demo_mode}
  def update_profile_settings(_profile, _attrs) do
    {:error, :demo_mode}
  end

  @doc """
  Creates a profile (no-op for demo users).
  """
  @spec create_profile(any(), any()) :: {:error, :demo_mode}
  def create_profile(_user, _attrs) do
    {:error, :demo_mode}
  end

  @doc """
  Gets the avatar URL for a profile, with fallback to default.
  """
  @spec avatar_url(ProfileSchema.t() | map() | nil, atom()) :: String.t()
  def avatar_url(profile, version \\ :original)

  def avatar_url(nil, _version) do
    AvatarUtils.generate_fallback_data_uri(nil)
  end

  def avatar_url(%ProfileSchema{} = profile, _version) do
    case profile.avatar do
      nil -> AvatarUtils.generate_fallback_data_uri(profile)
      "" -> AvatarUtils.generate_fallback_data_uri(profile)
      avatar -> avatar
    end
  end

  def avatar_url(profile, _version) when is_map(profile) do
    case Map.get(profile, :avatar) || Map.get(profile, "avatar") do
      nil -> AvatarUtils.generate_fallback_data_uri(profile)
      "" -> AvatarUtils.generate_fallback_data_uri(profile)
      avatar -> avatar
    end
  end

  @doc """
  Gets the alt text for avatar images.
  """
  @spec avatar_alt_text(ProfileSchema.t() | map() | nil) :: String.t()
  def avatar_alt_text(nil), do: "User avatar"

  def avatar_alt_text(%ProfileSchema{} = profile) do
    full_name = profile.full_name || "User"
    "#{full_name}'s avatar"
  end

  def avatar_alt_text(profile) when is_map(profile) do
    full_name = Map.get(profile, :full_name) || Map.get(profile, "full_name") || "User"
    "#{full_name}'s avatar"
  end
end
