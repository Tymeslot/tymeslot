defmodule Tymeslot.Dashboard.DashboardContext do
  @moduledoc """
  Context module for dashboard business logic.
  Extracted from dashboard_live.ex to improve separation of concerns.
  """

  require Logger

  alias Tymeslot.Agenda
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Video
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Venues

  @typep integration_status :: %{
           has_calendar: boolean(),
           has_video: boolean(),
           has_meeting_types: boolean()
         }

  @doc """
  Returns the default (empty) integration status map.
  Used as a fallback when the status read times out or fails.
  """
  @spec default_integration_status() :: integration_status()
  def default_integration_status,
    do: %{has_calendar: false, has_video: false, has_meeting_types: false}

  @doc """
  Whether the user has set up each part the dashboard nudges them towards: a
  calendar a booking can be written to, a video integration, an active
  meeting type.

  Read fresh every time rather than cached, so a change made anywhere (another
  tab, a background job, a reconnect) shows on the next mount or refresh
  without any writer having to announce it. Each part is one indexed EXISTS
  query.
  """
  @spec get_integration_status(integer()) :: integration_status()
  def get_integration_status(user_id) when is_integer(user_id) do
    %{
      has_calendar: Calendar.has_bookable_integration?(user_id),
      has_video: Video.has_active_integration?(user_id),
      has_meeting_types: MeetingTypes.has_active_meeting_types?(user_id)
    }
  rescue
    # The status only decides which set-up reminders the sidebar shows, so a
    # database that cannot answer leaves the dashboard up with the defaults
    # rather than failing its mount.
    exception ->
      Logger.warning("Integration status read failed; showing defaults",
        user_id: user_id,
        error: Exception.message(exception)
      )

      default_integration_status()
  end

  @spec get_integration_status(nil | any()) :: integration_status()
  def get_integration_status(_user_id), do: default_integration_status()

  @doc """
  Gather meeting settings data for a user (meeting types and video integrations).
  """
  @spec get_meeting_settings_data(integer()) :: %{
          meeting_types: list(),
          video_integrations: list(),
          calendar_integrations: list(),
          venues: list()
        }
  def get_meeting_settings_data(user_id) when is_integer(user_id) do
    %{
      meeting_types: MeetingTypes.get_all_meeting_types(user_id),
      video_integrations: Video.list_active_integrations(user_id),
      calendar_integrations: Management.list_calendar_integrations(user_id),
      venues: Venues.list_venues(user_id)
    }
  end

  @spec get_meeting_settings_data(nil | any()) :: %{
          meeting_types: list(),
          video_integrations: list(),
          calendar_integrations: list(),
          venues: list()
        }
  def get_meeting_settings_data(_user_id),
    do: %{meeting_types: [], video_integrations: [], calendar_integrations: [], venues: []}

  @doc """
  Gets dashboard-specific data for a given action.

  For the `:overview` and `:calendar` actions, builds the live agenda
  (`Agenda.Day`) for the user in their timezone — the merged Today/Tomorrow
  view of bookings and synced calendar events. The calendar uses it for the
  "Up next" strip above the grid. Other actions need no extra data and return
  an empty map.

  ## Examples

      iex> get_dashboard_data_for_action(user, "Europe/Berlin", :overview)
      %{agenda: %Tymeslot.Agenda.Day{}}

      iex> get_dashboard_data_for_action(user, "Europe/Berlin", :settings)
      %{}
  """
  @spec get_dashboard_data_for_action(map(), String.t() | nil, atom()) :: map()
  def get_dashboard_data_for_action(%{email: email} = user, timezone, action)
      when is_binary(email) and action in [:overview, :calendar] do
    %{agenda: Agenda.day_agenda(user, timezone)}
  end

  def get_dashboard_data_for_action(_user, _timezone, _action), do: %{}
end
