defmodule TymeslotWeb.Themes.Shared.CalendarDownload do
  @moduledoc """
  The "Add to calendar" link on a theme's confirmation step.

  A solo booking downloads its meeting's file under the organiser's username
  and the meeting uid (`TymeslotWeb.MeetingCalendarController.show/2`). A seat
  on a group meeting downloads the seat's own file under its management
  token (`:seat_calendar_url`, set when the seat was booked): the meeting uid
  of a group meeting names the shared slot, which is never the booker's to
  hold, export or manage.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router,
    statics: TymeslotWeb.static_paths()

  @doc "The link's href, or `nil` when there is no booking to download."
  @spec href(map()) :: String.t() | nil
  def href(%{seat_calendar_url: url}) when is_binary(url) and url != "", do: url

  def href(%{meeting_uid: uid, username_context: username})
      when is_binary(uid) and uid != "" and is_binary(username) and username != "",
      do: ~p"/#{username}/meeting/#{uid}/calendar.ics"

  def href(_assigns), do: nil
end
