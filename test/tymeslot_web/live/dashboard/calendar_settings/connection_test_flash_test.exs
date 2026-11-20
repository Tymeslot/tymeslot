defmodule TymeslotWeb.Dashboard.CalendarSettings.ConnectionTestFlashTest do
  @moduledoc """
  The flash a connection test leaves reads as a sentence: a failure the test
  already worded is shown as it stands, not as a quoted string.

  `CalendarSettingsComponent` renders no control for the "test_connection"
  event (see `calendar_settings_composition_test.exs`), so the handler is
  called directly.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.CalendarSettingsComponent

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    RateLimiter.clear_all()
    %{user: insert(:user)}
  end

  defp test_connection(user, integration) do
    socket = %Phoenix.LiveView.Socket{assigns: %{current_user: user}}
    params = %{"id" => to_string(integration.id)}

    assert {:noreply, _socket} =
             CalendarSettingsComponent.handle_event("test_connection", params, socket)

    assert_received {:flash, {:error, message}}
    message
  end

  test "shows a failure the test worded as it stands", %{user: user} do
    stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
      {:error, %Mint.TransportError{reason: :timeout}}
    end)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: "https://cal.example.com",
        is_active: true
      )

    assert "Connection test failed: CalDAV server did not respond in time." <> rest =
             test_connection(user, integration)

    refute rest =~ ~s(")
  end
end
