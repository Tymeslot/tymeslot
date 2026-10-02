defmodule TymeslotWeb.Components.Dashboard.Meetings.Helpers do
  @moduledoc """
  Helpers for meeting display and policy checks in the dashboard.
  """

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Meetings.Guests
  alias TymeslotWeb.Dashboard.DashboardFormat

  # Status helpers
  @spec past_meeting?(Ecto.Schema.t()) :: boolean()
  def past_meeting?(meeting) do
    DateTime.compare(meeting.end_time, DateTime.utc_now()) == :lt
  end

  # Policy helpers (surface booleans)
  @spec can_cancel?(Ecto.Schema.t()) :: boolean()
  def can_cancel?(meeting) do
    case Policy.can_cancel_meeting?(meeting) do
      :ok -> true
      {:error, _reason} -> false
    end
  end

  @doc """
  Whether the host may still add guests to this booking: the meeting takes
  guests (`Guests.invitations_open?/1`) and has room for another.

  The meeting type's `allow_guests` is deliberately not consulted — it governs
  what the person booking may do on the public form, not whom the host may
  invite to their own meeting afterwards.

  Counted from the guests preloaded onto the card, so a list of bookings does
  not turn into one query per row.
  """
  @spec can_add_guests?(Ecto.Schema.t() | map()) :: boolean()
  def can_add_guests?(%{guests: guests} = meeting) when is_list(guests),
    do: Guests.invitations_open?(meeting) and length(guests) < Guests.max_guests()

  def can_add_guests?(meeting), do: Guests.invitations_open?(meeting)

  @spec can_reschedule?(Ecto.Schema.t()) :: boolean()
  def can_reschedule?(meeting) do
    case Policy.can_reschedule_meeting?(meeting) do
      :ok -> true
      {:error, _reason} -> false
    end
  end

  # Timezone + formatting helpers
  @spec get_meeting_timezone(Ecto.Schema.t() | nil, Ecto.Schema.t() | nil) :: String.t()
  def get_meeting_timezone(nil, _profile), do: "UTC"
  def get_meeting_timezone(_meeting, nil), do: "UTC"

  def get_meeting_timezone(_meeting, profile) do
    # Organizer's timezone for the dashboard view
    (profile && profile.timezone) || "UTC"
  end

  @doc "The meeting's full date in the organiser's timezone. See `DashboardFormat.long_date/1`."
  @spec format_meeting_date(Ecto.Schema.t(), String.t()) :: String.t()
  def format_meeting_date(meeting, timezone),
    do: meeting.start_time |> DashboardFormat.local_date(timezone) |> DashboardFormat.long_date()

  @doc """
  Formats a meeting's time range for the organiser's dashboard. See
  `DashboardFormat.time_range/4`.

  Takes the clock format explicitly rather than defaulting it: the dashboard is
  organiser-facing and must follow their preference, so a call site that has
  not thought about which clock to use should fail to compile rather than
  quietly pick one.
  """
  @spec format_meeting_time(Ecto.Schema.t(), String.t(), String.t()) :: String.t()
  def format_meeting_time(meeting, timezone, time_format),
    do: DashboardFormat.time_range(meeting.start_time, meeting.end_time, timezone, time_format)
end
