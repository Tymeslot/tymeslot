defmodule Tymeslot.Demo.Behaviour do
  @moduledoc """
  Behavior for demo/showcase functionality.

  Core provides this interface and a no-op implementation.
  SaaS can provide a real implementation for theme showcasing on the homepage.
  """

  @doc """
  Gets a profile by ID (returns demo profile if applicable).
  """
  @callback get_profile_by_id(profile_id :: integer()) :: map() | nil

  @doc """
  Gets a user by ID (returns demo user if applicable).
  """
  @callback get_user_by_id(user_id :: integer()) :: map() | nil

  @doc """
  Gets a profile by user ID.
  """
  @callback get_profile_by_user_id(user_id :: integer()) :: map() | nil

  @doc """
  Checks if a username is a demo username (e.g., demo-theme-1).
  """
  @callback demo_username?(username :: String.t() | any()) :: boolean()

  @doc """
  Checks if a profile is a demo profile.
  """
  @callback demo_profile?(profile :: map() | nil) :: boolean()

  @doc """
  Checks if a socket/context is in demo mode.
  """
  @callback demo_mode?(context :: map()) :: boolean()

  @doc """
  Gets a profile by username (returns demo profile if applicable).
  """
  @callback get_profile_by_username(username :: String.t()) :: map() | nil

  @doc """
  Resolves organizer context for a username.
  """
  @callback resolve_organizer_context(username :: String.t()) ::
              {:ok, map()} | {:error, :profile_not_found}

  @doc """
  Resolves organizer context (optimized version).
  """
  @callback resolve_organizer_context_optimized(username :: String.t()) ::
              {:ok, map()} | {:error, :profile_not_found}

  @doc """
  Gets theme customization for a profile and theme.
  """
  @callback get_theme_customization(profile_id :: integer(), theme_id :: String.t()) :: any()

  @doc """
  Gets weekly schedule for a profile.
  """
  @callback get_weekly_schedule(profile_id :: integer()) :: [map()]

  @doc """
  Lists active meeting types for a user.
  """
  @callback list_active_meeting_types(user_id :: integer()) :: [map()]

  @doc """
  Gets active video integration for a user.
  """
  @callback get_active_video_integration(user_id :: integer()) :: map() | nil

  @doc """
  Lists calendar integrations for a user.
  """
  @callback list_calendar_integrations(user_id :: integer()) :: [map()]

  @doc """
  Gets avatar URL for a profile.
  """
  @callback avatar_url(profile :: map() | nil, version :: atom()) :: String.t()

  @doc """
  Gets avatar alt text for a profile.
  """
  @callback avatar_alt_text(profile :: map() | nil) :: String.t()

  @doc """
  Finds meeting type by slug.
  """
  @callback find_by_slug(user_id :: integer(), slug :: String.t()) ::
              map() | nil

  @doc """
  Finds meeting type by duration string.
  """
  @callback find_by_duration_string(user_id :: integer(), duration_string :: String.t()) ::
              map() | nil

  @doc """
  Gets the orchestrator module to use.
  """
  @callback get_orchestrator(context :: map()) :: module()

  @doc """
  Gets available slots for a date.
  """
  @callback get_available_slots(
              date_string :: String.t(),
              duration :: String.t() | integer(),
              user_timezone :: String.t(),
              organizer_user_id :: integer(),
              organizer_profile :: map(),
              context :: map() | nil
            ) :: {:ok, [map()]} | {:error, any()}

  @doc """
  Gets month availability map showing which days have actual free slots.
  """
  @callback get_month_availability(
              user_id :: integer(),
              year :: integer(),
              month :: integer(),
              user_timezone :: String.t(),
              organizer_profile :: map(),
              context :: map() | nil,
              duration_minutes :: integer() | nil
            ) :: {:ok, map()} | {:error, any()}

  @doc """
  Gets calendar days for a month.
  """
  @callback get_calendar_days(
              user_timezone :: String.t(),
              year :: integer(),
              month :: integer(),
              organizer_profile :: map(),
              availability_map :: map() | atom() | nil
            ) :: [map()]
end
