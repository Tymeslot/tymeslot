defmodule TymeslotWeb.Dashboard.Availability.TimeOffCardNilTimezoneTest do
  @moduledoc """
  The time-off card for a host who never set a timezone: their hours and time
  off are read on the default zone (`Tymeslot.Profiles.timezone/1`), so a
  booking inside the time off is found, and shown, on that clock.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :availability
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  setup %{conn: conn} do
    AvailabilityCache.clear_all()
    {:ok, ctx} = setup_dashboard_user(%{conn: conn})
    {:ok, _schedule} = Schedules.create_default(ctx[:profile].id)

    ctx
  end

  describe "a host who never set a timezone" do
    # Their hours and time off are read on the default zone, Europe/Tallinn,
    # whatever zone their browser reports. 00:30 there is the evening before
    # in UTC, and the afternoon before in New York.
    setup %{profile: profile} do
      profile |> Changeset.change(timezone: nil) |> Repo.update!()
      %{day: Date.add(Date.utc_today(), 30)}
    end

    for {label, browser_zone} <- [{"", nil}, {", with a browser in New York", "America/New_York"}] do
      test "sees a booking inside the time off on the clock it is read on#{label}", %{
        conn: conn,
        user: user,
        day: day
      } do
        start_time =
          day
          |> DateTime.new!(~T[00:30:00], Profiles.get_default_timezone())
          |> DateTime.shift_zone!("Etc/UTC")

        booking(user, start_time, "Night call")

        conn =
          case unquote(browser_zone) do
            nil -> conn
            zone -> put_connect_params(conn, %{"timezone" => zone})
          end

        {:ok, view, _html} = live(conn, ~p"/dashboard/availability")
        view |> element("[data-testid='add-time-off']") |> render_click()

        html =
          view
          |> form("#time-off-form-modal-form", %{
            "starts_on" => Date.to_iso8601(day),
            "ends_on" => Date.to_iso8601(Date.add(day, 1))
          })
          |> render_change()

        shown = Calendar.strftime(day, "%A %-d %B") <> ", 12:30 AM"
        assert html =~ ~r/#{shown}\s*<\/span><span class="font-medium">Night call/
      end
    end
  end

  defp booking(user, start_time, title) do
    insert(:meeting,
      organizer_user_id: user.id,
      title: title,
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute)
    )
  end
end
