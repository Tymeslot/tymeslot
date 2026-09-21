defmodule TymeslotWeb.Dashboard.CalendarSettings.RateLimitTest do
  @moduledoc """
  Tests that the calendar settings component correctly handles rate-limit
  exhaustion for discovery and connection testing. Runs with `async: false`
  because rate-limit state lives in a shared ETS table.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :live
  @moduletag :security

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.CalendarSettingsComponent

  setup :setup_dashboard_user

  setup do
    RateLimiter.clear_all()
    :ok
  end

  describe "discover_calendars rate limit" do
    test "shows error when calendar discovery rate limit is exceeded", %{conn: conn, user: user} do
      # Pre-exhaust the per-user discovery limit (30 per 10 minutes). Discovery
      # is keyed on a resolved actor, not a bare id.
      for _i <- 1..30 do
        RateLimiter.check_connection_test_rate_limit(:discovery, {:user, user.id})
      end

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      # Open the CalDAV config form via its picker option.
      view
      |> element("button[phx-click='connect_provider'][phx-value-provider='caldav']")
      |> render_click()

      # Submit the discovery form — should be rate-limited
      view
      |> form("form[phx-submit='discover_calendars']", %{
        integration: %{
          url: "https://cal.example.com",
          username: "user",
          password: "pass",
          provider: "caldav"
        }
      })
      |> render_submit()

      assert render(view) =~ "reached the limit"
    end
  end

  describe "test_connection rate limit" do
    test "rate limiter rejects after bucket is exhausted", %{user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)

      # Exhaust the per-user connection test limit (20 per 10 minutes)
      for _i <- 1..20 do
        assert :ok = RateLimiter.check_connection_test_rate_limit(:caldav, {:user, user.id})
      end

      # The next call must be rejected
      assert {:error, :rate_limited, message} =
               RateLimiter.check_connection_test_rate_limit(:caldav, {:user, user.id})

      assert message =~ "reached the limit"
    end

    test "one click costs exactly one token — no LiveView-side pre-check double charge", %{
      user: user
    } do
      # `CalendarSettingsComponent` has no UI element wired to the
      # "test_connection" event today (see
      # `calendar_settings_composition_test.exs`), so this exercises the
      # handler directly rather than through a rendered button.
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "http://localhost:1",
          is_active: true
        )

      socket = %Phoenix.LiveView.Socket{assigns: %{current_user: user}}
      params = %{"id" => to_string(integration.id)}
      click = fn -> CalendarSettingsComponent.handle_event("test_connection", params, socket) end

      flush_flash = fn ->
        receive do
          {:flash, _message} -> :ok
        after
          0 -> :ok
        end
      end

      # 19 clicks leave exactly one call of headroom in the 20-per-window
      # budget. If the handler charged two tokens per click (its own
      # pre-check plus the provider's), the bucket would already be
      # exhausted well before this point.
      for _i <- 1..19, do: click.()
      for _i <- 1..19, do: flush_flash.()

      assert {:noreply, _socket} = click.()
      assert_received {:flash, {:error, msg}}
      refute msg =~ "reached the limit"

      # The 21st call is the first to exceed the budget.
      assert {:noreply, _socket} = click.()
      assert_received {:flash, {:error, msg}}
      assert msg =~ "reached the limit"
    end
  end

  describe "add_subscription rate limit" do
    test "a rate-limited subscription submission is refused without writing a row", %{
      conn: conn,
      user: user
    } do
      # Exhaust the per-user integration write limit (30 per 30 minutes).
      # `create_subscription_with_validation/3` charges it once the form has
      # validated and before the feed probe runs, so the refusal arrives with
      # no outbound request made.
      for _i <- 1..30 do
        assert :ok = RateLimiter.check_integration_write_rate_limit(user.id)
      end

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      view
      |> element("button[phx-click='connect_provider'][phx-value-provider='ics_url']")
      |> render_click()

      view
      |> form("#calendar-subscription-form", %{
        "integration" => %{
          "name" => "Work calendar",
          "url" => "https://feeds.example.com/secret-token/calendar.ics"
        }
      })
      |> render_submit()

      # The submission runs off-socket via `start_async/3`, so the refusal only
      # reaches the form once that task has settled.
      assert render_async(view) =~ "reached the limit"

      refute Repo.get_by(CalendarIntegrationSchema, user_id: user.id, provider: "ics_url")
    end

    test "a feed URL the validator rejects leaves the write budget untouched", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      view
      |> element("button[phx-click='connect_provider'][phx-value-provider='ics_url']")
      |> render_click()

      # More submissions than the write budget holds (30 per 30 minutes), each
      # refused by the validator before anything is written or fetched.
      for _i <- 1..35 do
        view
        |> form("#calendar-subscription-form", %{
          "integration" => %{"name" => "Work calendar", "url" => "javascript:alert(1)"}
        })
        |> render_submit()

        render_async(view)
      end

      refute Repo.get_by(CalendarIntegrationSchema, user_id: user.id, provider: "ics_url")

      # The budget meters writes, and nothing above wrote anything: an organiser
      # correcting a mistyped feed URL must not be locked out by their
      # corrections.
      for _i <- 1..30 do
        assert :ok = RateLimiter.check_integration_write_rate_limit(user.id)
      end

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_integration_write_rate_limit(user.id)
    end
  end
end
