defmodule TymeslotWeb.Dashboard.CalendarSettings.AppearanceTest do
  @moduledoc """
  Renaming a calendar integration and choosing the colour its events are shown
  in, from the "Manage calendars" modal. Runs with `async: false` because both
  actions draw on the shared integration-write rate limiter.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :live
  @moduletag :calendar

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup :setup_dashboard_user

  setup do
    RateLimiter.clear_all()
    :ok
  end

  defp open_manage_modal(conn, integration) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    view
    |> element("button[phx-click='manage_calendars'][phx-value-id='#{integration.id}']")
    |> render_click()

    view
  end

  defp reload(integration, user) do
    {:ok, reloaded} = Calendar.get_integration(integration.id, user.id)
    reloaded
  end

  # The picker only ever pushes ids the user owns and keys from the palette, so
  # the rejecting branches are reached the way a hand-crafted client would
  # reach them: the real swatch, with the pushed values overridden.
  defp swatch(view, integration, colour) do
    element(
      view,
      "button[phx-click='set_integration_colour'][phx-value-colour='#{colour}'][phx-value-integration_id='#{integration.id}']"
    )
  end

  describe "renaming an integration" do
    test "stores the new name", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, name: "Calendar")
      view = open_manage_modal(conn, integration)

      view
      |> form("form[phx-submit='rename_integration']", %{name: "Work"})
      |> render_submit()

      assert reload(integration, user).name == "Work"
      assert render(view) =~ "Calendar renamed"
    end

    test "trims surrounding whitespace", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user)
      view = open_manage_modal(conn, integration)

      view
      |> form("form[phx-submit='rename_integration']", %{name: "  Work  "})
      |> render_submit()

      assert reload(integration, user).name == "Work"
    end

    test "rejects a name longer than the connection form allows", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, name: "Calendar")
      view = open_manage_modal(conn, integration)

      # Well past the 100-character limit and past the column's 255, which is
      # where an unvalidated rename would raise instead of failing cleanly.
      view
      |> form("form[phx-submit='rename_integration']", %{name: String.duplicate("a", 300)})
      |> render_submit()

      assert reload(integration, user).name == "Calendar"
    end

    test "rejects a blank name", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, name: "Calendar")
      view = open_manage_modal(conn, integration)

      view
      |> form("form[phx-submit='rename_integration']", %{name: "   "})
      |> render_submit()

      assert reload(integration, user).name == "Calendar"
    end

    test "refuses once the write rate limit is spent", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, name: "Calendar")
      view = open_manage_modal(conn, integration)

      exhaust_appearance_limit(user)

      view
      |> form("form[phx-submit='rename_integration']", %{name: "Work"})
      |> render_submit()

      assert reload(integration, user).name == "Calendar"
      assert render(view) =~ "limit"
    end
  end

  describe "choosing an integration colour" do
    test "stores the chosen palette key", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user)
      view = open_manage_modal(conn, integration)

      view
      |> swatch(integration, "peacock")
      |> render_click()

      assert reload(integration, user).colour == "peacock"
    end

    test "the Automatic pill clears the colour", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, colour: "peacock")
      view = open_manage_modal(conn, integration)

      view
      |> swatch(integration, "default")
      |> render_click()

      assert reload(integration, user).colour == nil
    end

    test "marks the stored colour as pressed", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, colour: "grape")
      view = open_manage_modal(conn, integration)

      assert has_element?(
               view,
               "button[phx-value-colour='grape'][aria-pressed='true']"
             )
    end

    test "refuses a colour outside the palette", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user)
      view = open_manage_modal(conn, integration)

      view
      |> swatch(integration, "peacock")
      |> render_click(%{"colour" => "burnt-sienna"})

      assert reload(integration, user).colour == nil
      assert render(view) =~ "Failed to update colour"
    end

    test "leaves another user's integration alone", %{conn: conn, user: user} do
      # Both handlers reach the row through the same ownership-scoped lookup,
      # so proving it once through the colour swatch covers the rename too.
      mine = insert(:calendar_integration, user: user)
      theirs = insert(:calendar_integration, user: insert(:user), colour: nil)
      view = open_manage_modal(conn, mine)

      view
      |> swatch(mine, "grape")
      |> render_click(%{"integration_id" => to_string(theirs.id)})

      assert Repo.get!(CalendarIntegrationSchema, theirs.id).colour == nil
      assert render(view) =~ "no longer available"
    end

    test "reports an integration that has gone away", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user)
      view = open_manage_modal(conn, integration)

      Calendar.delete_integration(integration.id, user.id)

      view
      |> swatch(integration, "grape")
      |> render_click()

      assert render(view) =~ "no longer available"
    end

    test "rejects a non-numeric integration id", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user)
      view = open_manage_modal(conn, integration)

      view
      |> swatch(integration, "grape")
      |> render_click(%{"integration_id" => "not-an-id"})

      assert render(view) =~ "Invalid calendar ID"
    end

    test "refuses once the appearance rate limit is spent", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user)
      view = open_manage_modal(conn, integration)

      exhaust_appearance_limit(user)

      view
      |> swatch(integration, "grape")
      |> render_click()

      assert reload(integration, user).colour == nil
      assert render(view) =~ "limit"
    end

    test "a spent connection-write budget does not block recolouring", %{conn: conn, user: user} do
      # Toggling calendars and connecting accounts draw on the shared write
      # bucket; picking a colour must not be refused because that one is gone.
      integration = insert(:calendar_integration, user: user)
      view = open_manage_modal(conn, integration)

      exhaust_write_limit(user)

      view
      |> swatch(integration, "grape")
      |> render_click()

      assert reload(integration, user).colour == "grape"
    end

    test "re-clicking the current colour spends no budget", %{conn: conn, user: user} do
      # Comparing colours by clicking around the grid is the intended use, and
      # each idle click used to cost a write and a token.
      integration = insert(:calendar_integration, user: user, colour: "grape")
      view = open_manage_modal(conn, integration)

      for _i <- 1..40 do
        view |> swatch(integration, "grape") |> render_click()
      end

      assert :ok = RateLimiter.check_integration_appearance_rate_limit(user.id)
      assert reload(integration, user).colour == "grape"
      refute render(view) =~ "limit"
    end

    test "the Automatic pill is a no-op when no colour is set", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, colour: nil)
      view = open_manage_modal(conn, integration)

      for _i <- 1..40 do
        view |> swatch(integration, "default") |> render_click()
      end

      assert :ok = RateLimiter.check_integration_appearance_rate_limit(user.id)
      assert reload(integration, user).colour == nil
    end
  end

  describe "the grid colour that follows from the choice" do
    test "a chosen colour is what the grid paints the integration's events", %{user: user} do
      integration = insert(:calendar_integration, user: user, colour: "peacock")

      classes = CalendarGrid.integration_colour_classes([integration])

      assert classes[integration.id] == EventColour.tailwind_class("peacock")
    end
  end

  # Spends a per-user bucket so the next draw on it is refused.
  defp exhaust_write_limit(user),
    do: exhaust(fn -> RateLimiter.check_integration_write_rate_limit(user.id) end)

  defp exhaust_appearance_limit(user),
    do: exhaust(fn -> RateLimiter.check_integration_appearance_rate_limit(user.id) end)

  defp exhaust(check) do
    Enum.reduce_while(1..1000, :ok, fn _i, _acc ->
      case check.() do
        :ok -> {:cont, :ok}
        {:error, :rate_limited, _message} -> {:halt, :ok}
      end
    end)
  end
end
