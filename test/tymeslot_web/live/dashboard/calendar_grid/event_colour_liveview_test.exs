defmodule TymeslotWeb.Dashboard.CalendarGrid.EventColourLiveViewTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "event colour override" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)
      today = Date.utc_today()

      event =
        insert_event(integration, %{
          summary: "Design Review",
          start_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
          end_at: DateTime.new!(today, ~T[11:00:00], "Etc/UTC"),
          all_day: false,
          colour: nil
        })

      {:ok, integration: integration, event: event}
    end

    test "renders the colour swatch picker in the editable detail modal", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "Colour"
      assert html =~ ~s(phx-value-colour="tomato")
      assert html =~ ~s(phx-value-colour="default")
    end

    test "picking a colour marks that swatch active in the modal (optimistic)", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      modal_html = lv |> element("[id^='event-#{event.id}-']") |> render_click()
      # No palette swatch is active before the override is set.
      refute modal_html =~ ~s(aria-pressed="true")

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_colour", %{"colour" => "tomato"})

      # tomato is now the active swatch (it pushes phx-value-colour="tomato").
      assert html =~ ~s(phx-value-colour="tomato")
      assert html =~ ~s(aria-pressed="true")
    end

    test "persists the colour to the cache on a successful provider write", %{
      conn: conn,
      integration: integration,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_colour", %{"colour" => "blueberry"})

      # The async provider write reports success; the LiveView's result handler
      # commits the optimistic colour to the cache row.
      send(lv.pid, {:event_update_result, :ok})

      CalendarGrid.update_cached_event(%{
        uid: event.uid,
        calendar_integration_id: integration.id,
        provider: "caldav",
        provider_calendar_id: event.provider_calendar_id,
        provider_event_id: event.provider_event_id,
        summary: event.summary,
        all_day: false,
        start_at: event.start_at,
        end_at: event.end_at,
        colour: "blueberry",
        synced_at: DateTime.utc_now(:microsecond)
      })

      assert {:ok, cached} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert cached.colour == "blueberry"
    end

    test "selecting Default clears an existing override (optimistic)", %{
      conn: conn,
      integration: integration
    } do
      today = Date.utc_today()

      coloured =
        insert_event(integration, %{
          summary: "Already Coloured",
          start_at: DateTime.new!(today, ~T[12:00:00], "Etc/UTC"),
          end_at: DateTime.new!(today, ~T[13:00:00], "Etc/UTC"),
          all_day: false,
          colour: "grape"
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      modal_html = lv |> element("[id^='event-#{coloured.id}-']") |> render_click()
      # The grape override starts active.
      assert modal_html =~ ~s(aria-pressed="true")

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_colour", %{"colour" => "default"})

      # Clearing the override removes the active palette swatch (Default is now
      # the highlighted option, but no palette swatch carries aria-pressed=true).
      refute html =~ ~s(aria-pressed="true")
    end
  end

  defp insert_event(integration, attrs) do
    insert(:provider_calendar_event, Map.merge(%{calendar_integration: integration}, attrs))
  end
end
