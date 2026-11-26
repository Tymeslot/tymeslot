defmodule Tymeslot.Demo.Behaviour do
  @moduledoc """
  Behavior for demo/showcase functionality.

  Core provides this interface and a no-op implementation.
  SaaS can provide a real implementation for theme showcasing on the homepage.
  """

  @doc """
  Gets a user by ID (returns demo user if applicable).
  """
  @callback get_user_by_id(user_id :: integer()) :: map() | nil

  @doc """
  Gets a profile by user ID.
  """
  @callback get_profile_by_user_id(user_id :: integer()) :: map() | nil

  @doc """
  Whether `username` lies in the namespace the demo provider reserves for its
  demo pages, so no organiser may choose it (`Tymeslot.Profiles.ReservedPaths`).

  This answers reservation only, never identity: the reserved namespace may be
  wider than the usernames the provider actually serves, and an organiser who
  held such a username before it was reserved keeps it and keeps their own
  booking page. Whether a profile is a demo one is `c:demo_profile?/1`.
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
  Returns the booking window, in days, to advertise for a demo profile.

  Demo profiles are plain maps with no availability schedule behind them, so the
  figure cannot be read from the database the way it is for a real organiser.
  """
  @callback booking_window_days(profile :: map() | nil) :: pos_integer()

  @doc """
  Resolves organizer context for a username.
  """
  @callback resolve_organizer_context(username :: String.t()) ::
              {:ok, map()} | {:error, :profile_not_found}

  @doc """
  Gets theme customization for a profile and theme.
  """
  @callback get_theme_customization(
              scope :: integer() | {integer(), integer()},
              theme_id :: String.t()
            ) :: any()

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
  Gets the orchestrator module to use: a `Tymeslot.Bookings.Submitter`, or
  `:default` for a booking that is not a demo, which `Tymeslot.Demo` resolves
  to Core's real orchestrator.
  """
  @callback get_orchestrator(context :: map()) :: module() | :default

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
  Gets availability for a date range.
  """
  @callback get_range_availability(
              user_id :: integer(),
              start_date :: Date.t(),
              end_date :: Date.t(),
              user_timezone :: String.t(),
              organizer_profile :: map(),
              context :: map() | nil,
              duration_minutes :: integer() | nil
            ) :: {:ok, map()} | {:error, any()}

  @doc """
  Which days a demo profile's calendars offer: a predicate on a date, as the
  visitor in `user_timezone` sees it, or `nil` for a profile that is not a
  demo, whose calendars answer from its own schedule. Core builds the month
  grid and the week strip from the predicate, so both agree and a provider
  never assembles a calendar itself. A real availability map, once loaded,
  takes precedence over it.
  """
  @callback day_available_fn(organizer_profile :: map(), user_timezone :: String.t()) ::
              (Date.t() -> boolean()) | nil
end
