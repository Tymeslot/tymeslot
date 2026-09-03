defmodule TymeslotWeb.AnalyticsRouteSuppressionTest do
  @moduledoc """
  The meeting-request approval link carries a long-lived `Phoenix.Token` that
  authorises approving or declining a booking on the host's behalf. Loading
  analytics on that page would ship the token to the analytics vendor's
  script (which reports `location.pathname`) and to every intermediate proxy,
  so `TymeslotWeb.Layouts.analytics_scripts/1` renders nothing for it. This
  guards that suppression, and that it stays scoped to that one page.
  """

  # async: false — mutates the global :analytics_providers app env.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :components
  @moduletag :analytics

  setup do
    original = Application.get_env(:tymeslot, :analytics_providers)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:tymeslot, :analytics_providers)
        value -> Application.put_env(:tymeslot, :analytics_providers, value)
      end
    end)

    Application.put_env(:tymeslot, :analytics_providers, [
      %{
        provider: :umami,
        script_url: "https://analytics.example.com/script.js",
        website_id: "abc-123"
      }
    ])

    :ok
  end

  test "loads no analytics script on the meeting-request approval page", %{conn: conn} do
    # The token need not be valid: `MeetingRequestLive` renders an "invalid
    # request" state through the same LiveView rather than redirecting, and
    # the suppression is keyed on the LiveView module, not the token.
    html = conn |> get(~p"/meeting-request/not-a-real-token") |> html_response(200)

    refute html =~ "data-analytics-src"
    refute html =~ "requestIdleCallback"
  end

  test "still loads the analytics script on an ordinary page", %{conn: conn} do
    html = conn |> get(~p"/auth/login") |> html_response(200)

    assert html =~ ~s(data-analytics-src="https://analytics.example.com/script.js")
  end
end
