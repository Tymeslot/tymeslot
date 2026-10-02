defmodule TymeslotWeb.AnalyticsRouteSuppressionTest do
  @moduledoc """
  The meeting-request approval, password-reset and poll voting links carry a
  credential in the path that authorises an action on someone's behalf.
  Loading analytics on those pages would ship it to the analytics vendor's
  script (which reports `location.pathname`) and to every intermediate proxy,
  so `TymeslotWeb.Layouts.analytics_scripts/1` renders nothing for them. This
  guards that suppression, and that it stays scoped to those pages: the other
  actions of the same LiveViews keep their analytics.
  """

  # async: false — mutates the global :analytics_providers app env.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :components
  @moduletag :analytics

  import Tymeslot.Factory
  import Tymeslot.ThemeBookingFlowHelpers, only: [seed_booking_account: 3]

  @tracker ~s(data-analytics-src="https://analytics.example.com/script.js")

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

  test "loads no analytics script on the password-reset form", %{conn: conn} do
    # An unknown token still renders the form's LiveView (with an error), and
    # the suppression is keyed on the view and its action, not the token.
    html = conn |> get(~p"/auth/reset-password/not-a-real-token") |> html_response(200)

    refute html =~ "data-analytics-src"
  end

  test "loads no analytics script on the poll voting page", %{conn: conn} do
    %{user: user, profile: profile} = seed_booking_account("1", "poll-host", "Etc/UTC")
    poll = insert(:poll, user: user, title: "Roadmap sync")
    insert(:poll_time_slot, poll: poll)

    html = conn |> get("/#{profile.username}/poll/#{poll.token}") |> html_response(200)

    assert html =~ "Roadmap sync"
    refute html =~ "data-analytics-src"
  end

  test "still loads the analytics script on an ordinary page", %{conn: conn} do
    html = conn |> get(~p"/auth/login") |> html_response(200)

    assert html =~ @tracker
  end

  test "still loads the analytics script on the poll host's booking page", %{conn: conn} do
    %{profile: profile} = seed_booking_account("1", "booking-host", "Etc/UTC")

    html = conn |> get("/#{profile.username}") |> html_response(200)

    assert html =~ @tracker
  end
end
