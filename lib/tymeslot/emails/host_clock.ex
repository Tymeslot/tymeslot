defmodule Tymeslot.Emails.HostClock do
  @moduledoc """
  The clock a host reads their booking emails by: their timezone and their
  chosen 12- or 24-hour format. A user's own account emails read by the same
  clock (`for_user/2`, `format_datetime/3`).

  Resolved once per email from the meeting's organiser, for the
  host-addressed templates that render straight from a meeting rather than
  from `Tymeslot.Emails.AppointmentBuilder`'s payload. The payload resolves
  the same clock when it is built: the start and end already shifted into
  the host's zone (`:start_time_owner_tz`, `:end_time_owner_tz`) and their
  chosen format as `:organizer_time_format`. An organiser-less meeting reads
  in the platform default timezone and the locale's own clock.
  """

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Emails.Shared.Formatting
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.DateTimeUtils

  @type t :: %{timezone: String.t(), time_format: String.t() | nil}

  @doc """
  The host clock for `meeting`'s organiser. `locale` is the email's, which
  decides the clock when the host never chose one.
  """
  @spec for_meeting(map(), String.t()) :: t()
  def for_meeting(meeting, locale),
    do: %{timezone: timezone(meeting), time_format: time_format(meeting, locale)}

  @doc """
  The clock `user_id` reads their own account emails by: the same timezone and
  12- or 24-hour choice as their booking emails.
  """
  @spec for_user(integer(), String.t()) :: t()
  def for_user(user_id, locale), do: for_meeting(%{organizer_user_id: user_id}, locale)

  @doc """
  `datetime` as an email to `user_id` states a time: on their own clock, with
  the zone named.
  """
  @spec format_datetime(DateTime.t(), integer(), String.t()) :: String.t()
  def format_datetime(%DateTime{} = datetime, user_id, locale) do
    clock = for_user(user_id, locale)

    datetime
    |> DateTimeUtils.convert_to_timezone(clock.timezone)
    |> Formatting.format_datetime(locale, clock.time_format)
  end

  @doc """
  The organiser's timezone alone, for a sender that needs no clock format.
  """
  @spec timezone(map()) :: String.t()
  def timezone(%{organizer_user_id: nil}), do: Profiles.get_default_timezone()
  def timezone(%{organizer_user_id: user_id}), do: Profiles.get_user_timezone(user_id)
  def timezone(_meeting), do: Profiles.get_default_timezone()

  @doc """
  The organiser's 12- or 24-hour choice alone, or nil (the locale's own
  clock) for an organiser-less meeting.
  """
  @spec time_format(map(), String.t()) :: String.t() | nil
  def time_format(%{organizer_user_id: nil}, _locale), do: nil

  def time_format(%{organizer_user_id: user_id}, locale),
    do: CalendarGrid.get_user_time_format(user_id, locale)

  def time_format(_meeting, _locale), do: nil
end
