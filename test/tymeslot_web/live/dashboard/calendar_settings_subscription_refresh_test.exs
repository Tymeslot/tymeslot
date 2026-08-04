defmodule TymeslotWeb.Dashboard.CalendarSettingsSubscriptionRefreshTest do
  @moduledoc """
  "Refresh All" against a calendar subscription: the settings page must
  enqueue a real `SyncIcsCalendarWorker` job rather than running the
  no-op discovery path (which never fetches a feed).
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :integrations
  @moduletag :calendar
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncIcsCalendarWorker

  setup do
    RateLimiter.clear_all()
    :ok
  end

  setup :setup_dashboard_user

  describe "refresh_all_calendars" do
    @tag :capture_log
    test "a subscription integration is refreshed via SyncIcsCalendarWorker, not calendar discovery",
         %{conn: conn, user: user} do
      subscription =
        insert(:calendar_integration,
          user: user,
          provider: "ics_url",
          name: "Feed",
          is_active: true,
          base_url: "https://feeds.example.com",
          username_encrypted: nil,
          password_encrypted: nil,
          subscription_url_encrypted: Encryption.encrypt("https://feeds.example.com/feed.ics")
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      view
      |> element("button[phx-click='refresh_all_calendars']")
      |> render_click()

      eventually(fn ->
        rendered = render(view)
        assert rendered =~ "All calendars refreshed successfully"
      end)

      assert_enqueued(
        worker: SyncIcsCalendarWorker,
        args: %{"calendar_integration_id" => subscription.id}
      )
    end
  end
end
