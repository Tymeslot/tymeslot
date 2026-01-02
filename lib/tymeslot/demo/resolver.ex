defmodule Tymeslot.Demo.Resolver do
  @moduledoc """
  Resolver that routes profile and context lookups based on demo mode.

  This module determines whether to use demo data or real database data
  based on the context (demo mode flag or username pattern).
  """

  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.DatabaseSchemas.ProfileSchema
  alias Tymeslot.Demo.Availability
  alias Tymeslot.Demo.Integrations, as: DemoIntegrations
  alias Tymeslot.Demo.Profiles, as: DemoProfiles
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Profiles
  alias Tymeslot.TemplateDemo.Context

  @doc """
  Resolves profile by username, checking demo mode first.
  """
  @spec get_profile_by_username(String.t()) :: map() | nil
  def get_profile_by_username(username) when is_binary(username) do
    if Context.demo_username?(username) do
      DemoProfiles.get_profile_by_username(username)
    else
      Profiles.get_profile_by_username(username)
    end
  end

  @doc """
  Resolves organizer context, checking demo mode first.
  """
  @spec resolve_organizer_context(String.t()) :: {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context(username) when is_binary(username) do
    if Context.demo_username?(username) do
      DemoProfiles.resolve_organizer_context(username)
    else
      Profiles.resolve_organizer_context(username)
    end
  end

  @doc """
  Resolves organizer context optimized, checking demo mode first.
  """
  @spec resolve_organizer_context_optimized(String.t()) ::
          {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context_optimized(username) when is_binary(username) do
    if Context.demo_username?(username) do
      DemoProfiles.resolve_organizer_context_optimized(username)
    else
      Profiles.resolve_organizer_context_optimized(username)
    end
  end

  @doc """
  Gets theme customization, checking demo mode first.
  """
  @spec get_theme_customization(integer(), String.t()) :: any()
  def get_theme_customization(profile_id, theme_id)
      when is_integer(profile_id) and is_binary(theme_id) do
    if profile_id in [999_001, 999_002] do
      Tymeslot.Demo.ThemeCustomizations.get_by_profile_and_theme(profile_id, theme_id)
    else
      Tymeslot.ThemeCustomizations.get_by_profile_and_theme(profile_id, theme_id)
    end
  end

  @doc """
  Gets availability data, checking demo mode first.
  """
  @spec get_weekly_schedule(integer()) :: map() | nil
  def get_weekly_schedule(profile_id) when is_integer(profile_id) do
    if profile_id in [999_001, 999_002] do
      Availability.get_weekly_schedule(profile_id)
    else
      WeeklySchedule.get_weekly_schedule(profile_id)
    end
  end

  @doc """
  Gets meeting types, checking demo mode first.
  """
  @spec list_active_meeting_types(integer()) :: [map()]
  def list_active_meeting_types(user_id) when is_integer(user_id) do
    if user_id in [999_001, 999_002] do
      Tymeslot.Demo.MeetingTypes.list_active_meeting_types(user_id)
    else
      Tymeslot.MeetingTypes.get_active_meeting_types(user_id)
    end
  end

  @doc """
  Gets video integration, checking demo mode first.
  """
  @spec get_active_video_integration(integer()) :: map() | nil
  def get_active_video_integration(user_id) when is_integer(user_id) do
    if user_id in [999_001, 999_002] do
      DemoIntegrations.get_active_video_integration(user_id)
    else
      case VideoIntegrationQueries.get_default_for_user(user_id) do
        {:ok, integration} -> integration
        {:error, :not_found} -> nil
      end
    end
  end

  @doc """
  Gets calendar integrations, checking demo mode first.
  """
  @spec list_calendar_integrations(integer()) :: [map()]
  def list_calendar_integrations(user_id) when is_integer(user_id) do
    if user_id in [999_001, 999_002] do
      DemoIntegrations.list_calendar_integrations(user_id)
    else
      Calendar.list_integrations(user_id)
    end
  end

  @doc """
  Gets avatar URL, checking demo mode first.
  """
  @spec avatar_url(ProfileSchema.t() | map() | nil, atom()) :: String.t()
  def avatar_url(profile, version \\ :original)

  def avatar_url(%ProfileSchema{} = profile, version) do
    # Check if it's a demo profile by ID
    if profile.id in [999_001, 999_002] do
      DemoProfiles.avatar_url(profile, version)
    else
      Profiles.avatar_url(profile, version)
    end
  end

  def avatar_url(profile, version) when is_map(profile) do
    # Check if it's a demo profile by ID
    if Map.get(profile, :id) in [999_001, 999_002] do
      DemoProfiles.avatar_url(profile, version)
    else
      Profiles.avatar_url(profile, version)
    end
  end

  def avatar_url(nil, version), do: Profiles.avatar_url(nil, version)

  @doc """
  Gets avatar alt text, checking demo mode first.
  """
  @spec avatar_alt_text(ProfileSchema.t() | map() | nil) :: String.t()
  def avatar_alt_text(%ProfileSchema{} = profile) do
    # Check if it's a demo profile by ID
    if profile.id in [999_001, 999_002] do
      DemoProfiles.avatar_alt_text(profile)
    else
      Profiles.avatar_alt_text(profile)
    end
  end

  def avatar_alt_text(profile) when is_map(profile) do
    # Check if it's a demo profile by ID
    if Map.get(profile, :id) in [999_001, 999_002] do
      DemoProfiles.avatar_alt_text(profile)
    else
      Profiles.avatar_alt_text(profile)
    end
  end

  def avatar_alt_text(nil), do: Profiles.avatar_alt_text(nil)

  @doc """
  Finds meeting type by duration string, checking demo mode first.
  """
  @spec find_by_duration_string(integer(), String.t()) :: map() | nil
  def find_by_duration_string(user_id, duration_string)
      when is_integer(user_id) and is_binary(duration_string) do
    if user_id in [999_001, 999_002] do
      Tymeslot.Demo.MeetingTypes.find_by_duration_string(user_id, duration_string)
    else
      Tymeslot.MeetingTypes.find_by_duration_string(user_id, duration_string)
    end
  end
end
