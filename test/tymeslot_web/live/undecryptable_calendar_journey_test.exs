defmodule TymeslotWeb.UndecryptableCalendarJourneyTest do
  @moduledoc """
  A calendar integration whose stored credentials no longer decrypt (a
  changed key, a corrupt row) must not crash the pages its owner and their
  visitors use: the public booking page, and the dashboard's calendar list,
  where the owner reconnects it.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :scheduling
  @moduletag :live
  @moduletag :capture_log

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo

  # The readiness card's heading, matched from its apostrophe onwards, which
  # HEEx escapes.
  @not_ready_heading "show this scheduling page yet"

  # Random bytes stand in for ciphertext whose key is genuinely gone.
  defp insert_undecryptable(user, name) do
    insert(:calendar_integration,
      user: user,
      name: name,
      provider: "caldav",
      username_encrypted: :crypto.strong_rand_bytes(40),
      password_encrypted: :crypto.strong_rand_bytes(40)
    )
  end

  describe "the public booking page" do
    setup do
      user = insert(:user)

      profile =
        insert(:profile,
          user: user,
          username: "undecryptable-cal",
          booking_theme: "1",
          timezone: "Etc/UTC"
        )

      insert(:meeting_type, user: user, name: "Quick Chat", duration_minutes: 30, is_active: true)

      %{user: user, profile: profile}
    end

    test "still offers the booking flow beside a calendar that cannot be read", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      insert(:calendar_integration, user: user, name: "Healthy", provider: "caldav")
      stale = insert_undecryptable(user, "Stale")

      {:ok, view, _html} = live(conn, "/#{profile.username}")
      html = render(view)

      assert html =~ "Quick Chat"
      refute html =~ @not_ready_heading
      assert Repo.get!(CalendarIntegrationSchema, stale.id).needs_reauth
    end

    test "tells the visitor the page is unavailable when its only calendar cannot be read",
         %{conn: conn, user: user, profile: profile} do
      insert_undecryptable(user, "Stale")

      {:ok, view, _html} = live(conn, "/#{profile.username}")

      assert has_element?(view, "[data-testid='readiness-notice']")
      assert render(view) =~ @not_ready_heading
    end
  end

  describe "the dashboard calendar list" do
    setup :setup_dashboard_user

    test "lists the calendar that cannot be read so its owner can reconnect it", %{
      conn: conn,
      user: user
    } do
      insert(:calendar_integration, user: user, name: "Healthy calendar", provider: "caldav")
      insert_undecryptable(user, "Stale calendar")

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      assert html =~ "Healthy calendar"
      assert html =~ "Stale calendar"
    end
  end
end
