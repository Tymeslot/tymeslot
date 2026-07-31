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
end
