defmodule Tymeslot.Demo do
  @moduledoc """
  Facade module for demo functionality.

  This delegates to the configured demo provider (NoOp by default, or SaaS implementation).
  """

  @doc """
  Gets the configured demo provider module.
  """
  @spec provider() :: module()
  def provider do
    Application.get_env(:tymeslot, :demo_provider, Tymeslot.Demo.NoOp)
  end

  # Delegate all behavior functions to the provider

  @spec get_profile_by_id(integer()) :: map() | nil
  def get_profile_by_id(profile_id), do: provider().get_profile_by_id(profile_id)

  @spec get_user_by_id(integer()) :: map() | nil
  def get_user_by_id(user_id), do: provider().get_user_by_id(user_id)

  @spec get_profile_by_user_id(integer()) :: map() | nil
  def get_profile_by_user_id(user_id), do: provider().get_profile_by_user_id(user_id)

  @spec demo_username?(String.t() | any()) :: boolean()
  def demo_username?(username), do: provider().demo_username?(username)

  @spec demo_profile?(map() | nil) :: boolean()
  def demo_profile?(profile), do: provider().demo_profile?(profile)

  @spec demo_mode?(map()) :: boolean()
  def demo_mode?(context), do: provider().demo_mode?(context)

  @spec get_profile_by_username(String.t()) :: map() | nil
  def get_profile_by_username(username), do: provider().get_profile_by_username(username)

  @spec resolve_organizer_context(String.t()) :: {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context(username), do: provider().resolve_organizer_context(username)

  @spec resolve_organizer_context_optimized(String.t()) ::
          {:ok, map()} | {:error, :profile_not_found}
  def resolve_organizer_context_optimized(username),
    do: provider().resolve_organizer_context_optimized(username)

  @spec get_theme_customization(integer(), String.t()) :: any()
  def get_theme_customization(profile_id, theme_id),
    do: provider().get_theme_customization(profile_id, theme_id)

  @spec get_weekly_schedule(integer()) :: map() | nil
  def get_weekly_schedule(profile_id), do: provider().get_weekly_schedule(profile_id)

  @spec list_active_meeting_types(integer()) :: [map()]
  def list_active_meeting_types(user_id), do: provider().list_active_meeting_types(user_id)

  @spec get_active_video_integration(integer()) :: map() | nil
  def get_active_video_integration(user_id),
    do: provider().get_active_video_integration(user_id)

  @spec list_calendar_integrations(integer()) :: [map()]
  def list_calendar_integrations(user_id),
    do: provider().list_calendar_integrations(user_id)

  @spec avatar_url(map() | nil, atom()) :: String.t()
  def avatar_url(profile, version \\ :original), do: provider().avatar_url(profile, version)

  @spec avatar_alt_text(map() | nil) :: String.t()
  def avatar_alt_text(profile), do: provider().avatar_alt_text(profile)

  @spec find_by_slug(integer(), String.t()) :: map() | nil
  def find_by_slug(user_id, slug),
    do: provider().find_by_slug(user_id, slug)

  @spec find_by_duration_string(integer(), String.t()) :: map() | nil
  def find_by_duration_string(user_id, duration_string),
    do: provider().find_by_duration_string(user_id, duration_string)

  @spec get_orchestrator(map()) :: module()
  def get_orchestrator(context), do: provider().get_orchestrator(context)

  @spec get_available_slots(String.t(), String.t(), String.t(), integer(), map(), map() | nil) ::
          {:ok, [map()]} | {:error, any()}
  def get_available_slots(
        date_string,
        duration,
        user_timezone,
        organizer_user_id,
        organizer_profile,
        context \\ nil
      ),
      do:
        provider().get_available_slots(
          date_string,
          duration,
          user_timezone,
          organizer_user_id,
          organizer_profile,
          context
        )

  @spec get_range_availability(
          integer(),
          Date.t(),
          Date.t(),
          String.t(),
          map(),
          map() | nil,
          integer() | nil
        ) :: {:ok, map()} | {:error, any()}
  def get_range_availability(
        user_id,
        start_date,
        end_date,
        user_timezone,
        organizer_profile,
        context \\ nil,
        duration_minutes \\ nil
      ),
      do:
        provider().get_range_availability(
          user_id,
          start_date,
          end_date,
          user_timezone,
          organizer_profile,
          context,
          duration_minutes
        )

  @spec get_month_availability(
          integer(),
          integer(),
          integer(),
          String.t(),
          map(),
          map() | nil,
          integer() | nil
        ) :: {:ok, map()} | {:error, any()}
  def get_month_availability(
        user_id,
        year,
        month,
        user_timezone,
        organizer_profile,
        context \\ nil,
        duration_minutes \\ nil
      ),
      do:
        provider().get_month_availability(
          user_id,
          year,
          month,
          user_timezone,
          organizer_profile,
          context,
          duration_minutes
        )

  @spec get_calendar_days(String.t(), integer(), integer(), map(), map() | atom() | nil) ::
          [map()]
  def get_calendar_days(
        user_timezone,
        year,
        month,
        organizer_profile,
        availability_map \\ nil
      ),
      do:
        provider().get_calendar_days(
          user_timezone,
          year,
          month,
          organizer_profile,
          availability_map
        )
end
