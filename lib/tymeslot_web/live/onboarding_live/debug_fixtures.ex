defmodule TymeslotWeb.OnboardingLive.DebugFixtures do
  @moduledoc """
  Named states for the onboarding debug routes, chosen with `?fixture=<name>`.

  A fixture puts the wizard into a state that is slow or awkward to reach by
  hand (a connected calendar, a week preview that failed) so a step can be
  looked at in that state. It only ever changes assigns, never the database,
  and the LiveView applies it on the debug actions alone: on the real routes
  the parameter is ignored.

  Fixtures:

    * `calendar` - a bookable Google calendar is connected

  Any other name, including ones reserved for fixtures still to come, leaves
  the socket as it is.
  """

  import Kernel, except: [apply: 2]

  alias Phoenix.Component
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema

  @doc """
  Applies the fixture named `name` to the socket.
  """
  @spec apply(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  def apply(socket, "calendar") do
    Component.assign(socket,
      connected_calendars: [fake_calendar(socket.assigns)],
      booking_page_live: true
    )
  end

  def apply(socket, _name), do: socket

  # Never persisted, so it has no id; the calendar step reads only the
  # provider and the names shown on its connected row.
  defp fake_calendar(assigns) do
    %CalendarIntegrationSchema{
      name: "Google Calendar",
      provider: "google",
      provider_account_email: fake_email(assigns),
      is_active: true
    }
  end

  defp fake_email(%{current_user: %{email: email}}), do: email
  defp fake_email(_assigns), do: nil
end
