defmodule Tymeslot.Demo.NoOp do
  @moduledoc """
  No-op implementation of demo functionality for core-only deployments.

  All demo checks return false/nil, so core behavior proceeds normally
  without any demo special-casing.
  """
  @behaviour Tymeslot.Demo.Behaviour

  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.DatabaseQueries.UserQueries
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations

  @impl Tymeslot.Demo.Behaviour
  def get_profile_by_id(profile_id) when is_integer(profile_id) do
    Profiles.get_profile_by_id(profile_id)
  end

  @impl Tymeslot.Demo.Behaviour
  def get_user_by_id(user_id) when is_integer(user_id) do
    case UserQueries.get_user(user_id) do
      {:ok, user} -> user
      {:error, :not_found} -> nil
    end
  end

  @impl Tymeslot.Demo.Behaviour
  def get_profile_by_user_id(user_id) when is_integer(user_id) do
    Profiles.get_profile(user_id)
  end

  @impl Tymeslot.Demo.Behaviour
  def demo_username?(_username), do: false

  @impl Tymeslot.Demo.Behaviour
  def demo_profile?(_profile), do: false

  @impl Tymeslot.Demo.Behaviour
  def demo_mode?(_context), do: false

  @impl Tymeslot.Demo.Behaviour
  def get_profile_by_username(username) when is_binary(username) do
    Profiles.get_profile_by_username(username)
  end

  @impl Tymeslot.Demo.Behaviour
  def resolve_organizer_context(username) when is_binary(username) do
    Profiles.resolve_organizer_context(username)
  end

  @impl Tymeslot.Demo.Behaviour
  def resolve_organizer_context_optimized(username) when is_binary(username) do
    Profiles.resolve_organizer_context_optimized(username)
  end

  @impl Tymeslot.Demo.Behaviour
  def get_theme_customization(profile_id, theme_id)
      when is_integer(profile_id) and is_binary(theme_id) do
    ThemeCustomizations.get_by_profile_and_theme(profile_id, theme_id)
  end

  @impl Tymeslot.Demo.Behaviour
  def get_weekly_schedule(profile_id) when is_integer(profile_id) do
    WeeklySchedule.get_weekly_schedule(profile_id)
  end

  @impl Tymeslot.Demo.Behaviour
  def list_active_meeting_types(user_id) when is_integer(user_id) do
    MeetingTypes.get_active_meeting_types(user_id)
  end

  @impl Tymeslot.Demo.Behaviour
  def get_active_video_integration(_user_id) do
    # Since we removed the "default" flag, we return nil here.
    # Consumers should instead look at the specific meeting type's video integration.
    nil
  end

  @impl Tymeslot.Demo.Behaviour
  def list_calendar_integrations(user_id) when is_integer(user_id) do
    Calendar.list_integrations(user_id)
  end

  @impl Tymeslot.Demo.Behaviour
  def avatar_url(profile, version \\ :original) do
    Profiles.avatar_url(profile, version)
  end

  @impl Tymeslot.Demo.Behaviour
  def avatar_alt_text(profile) do
    Profiles.avatar_alt_text(profile)
  end

  @impl Tymeslot.Demo.Behaviour
  def find_by_slug(user_id, slug)
      when is_integer(user_id) and is_binary(slug) do
    MeetingTypes.find_by_slug(user_id, slug)
  end

  @impl Tymeslot.Demo.Behaviour
  def find_by_duration_string(user_id, duration_string)
      when is_integer(user_id) and is_binary(duration_string) do
    MeetingTypes.find_by_duration_string(user_id, duration_string)
  end

  @impl Tymeslot.Demo.Behaviour
  def get_orchestrator(_context), do: Tymeslot.Bookings.Orchestrator

  @impl Tymeslot.Demo.Behaviour
  def get_available_slots(
        _date_string,
        _duration,
        _user_timezone,
        _organizer_user_id,
        _organizer_profile,
        _context
      ) do
    # NoOp implementation returns empty list; caller should fall back to real logic
    {:ok, []}
  end

  @impl Tymeslot.Demo.Behaviour
  def get_month_availability(
        _user_id,
        _year,
        _month,
        _user_timezone,
        _organizer_profile,
        _context,
        _duration_minutes \\ nil
      ) do
    # NoOp implementation returns empty map; caller should fall back to real logic
    {:ok, %{}}
  end

  @impl Tymeslot.Demo.Behaviour
  def get_calendar_days(
        _user_timezone,
        _year,
        _month,
        _organizer_profile,
        _availability_map \\ nil
      ) do
    # NoOp implementation returns empty list; caller should fall back to real logic
    []
  end
end
