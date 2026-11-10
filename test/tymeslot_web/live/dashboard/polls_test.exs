defmodule TymeslotWeb.Dashboard.PollsTest do
  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  # A host with a profile, a username and a calendar integration: the
  # baseline for list/create/validation tests.
  defp setup_host(_context) do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    profile = insert(:profile, user: user, username: "host#{System.unique_integer([:positive])}")
    insert(:calendar_integration, user: user, provider: "debug")
    {:ok, conn: log_in(build_conn(), user), user: user, profile: profile}
  end

  defp log_in(conn, user) do
    conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
  end

  # ===========================================================================
  # Listing
  # ===========================================================================

  describe "Poll list" do
    setup :setup_host

    test "lists existing polls with their titles and status", %{conn: conn, user: user} do
      open_poll = insert(:poll, user: user, title: "Team sync", status: :open)
      base = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
      insert(:poll_time_slot, poll: open_poll, start_time: base)
      insert(:poll_time_slot, poll: open_poll, start_time: DateTime.add(base, 1, :hour))
      insert(:poll, user: user, title: "Roadmap review", status: :confirmed)

      {:ok, _view, html} = live(conn, ~p"/dashboard/polls")

      assert html =~ "Team sync"
      assert html =~ "Roadmap review"
      assert html =~ "Open"
      assert html =~ "Confirmed"
      assert html =~ "2 time options"
    end

    test "shows an empty state when the user has no polls", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/polls")

      assert html =~ "No polls yet"
    end

    test "with no polls, the empty state carries the only New poll button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      assert has_element?(view, "[data-testid='polls-empty'] button", "New poll")

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("button[phx-click='new_poll']")
             |> Enum.count() == 1

      view |> element("[data-testid='polls-empty'] button", "New poll") |> render_click()

      assert has_element?(view, "form[phx-submit='create_poll']")
      refute has_element?(view, "[data-testid='polls-empty']")
    end

    test "with polls listed, New poll sits once beside the page title", %{
      conn: conn,
      user: user
    } do
      insert(:poll, user: user, title: "Team sync", status: :open)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      refute has_element?(view, "[data-testid='polls-empty']")
      assert has_element?(view, "[data-testid='new-poll']", "New poll")

      doc = view |> render() |> LazyHTML.from_document()
      assert doc |> LazyHTML.query("button[phx-click='new_poll']") |> Enum.count() == 1

      assert doc
             |> LazyHTML.query("div:has(> div > h1) [data-testid='new-poll']")
             |> Enum.count() == 1
    end

    test "does not list polls belonging to other users", %{conn: conn} do
      other = insert(:user)
      insert(:poll, user: other, title: "Someone else's poll")

      {:ok, _view, html} = live(conn, ~p"/dashboard/polls")

      refute html =~ "Someone else's poll"
    end
  end

  # ===========================================================================
  # Creating
  # ===========================================================================

  describe "Creating a poll" do
    setup :setup_host

    test "creates a poll with candidate slots and shows it in the list", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view |> element("button", "New poll") |> render_click()

      # Empty required fields reach the server, which answers in the form.
      assert has_element?(view, "form[id^='poll-create-form-'][novalidate]")

      # Two candidate-slot rows.
      view |> element("button", "Add time") |> render_click()
      view |> element("button", "Add time") |> render_click()

      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      view
      |> form("form[phx-submit='create_poll']", %{
        "poll" => %{
          "title" => "Launch planning",
          "slots" => %{"0" => "#{date}T09:00", "1" => "#{date}T10:00"}
        }
      })
      |> render_submit(%{"poll" => %{"duration" => "30", "timezone" => "Europe/Tallinn"}})

      assert render(view) =~ "Launch planning"

      assert [poll] = Polls.list_polls(user.id)
      assert poll.title == "Launch planning"
      assert length(poll.time_slots) == 2
    end

    test "invites the people listed with the poll", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view |> element("button", "New poll") |> render_click()
      view |> element("button", "Add time") |> render_click()
      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      view
      |> form("form[phx-submit='create_poll']", %{
        "poll" => %{
          "title" => "Launch planning",
          "slots" => %{"0" => "#{date}T09:00"},
          "invitees" => "Grace Hopper <grace@example.com>, ada@example.com"
        }
      })
      |> render_submit(%{"poll" => %{"duration" => "30", "timezone" => "Europe/Tallinn"}})

      assert [poll] = Polls.list_polls(user.id)

      assert poll.participants |> Enum.map(& &1.email) |> Enum.sort() ==
               ["ada@example.com", "grace@example.com"]

      for participant <- poll.participants do
        assert_enqueued(
          worker: EmailWorker,
          args: %{"action" => "send_poll_invitation", "participant_id" => participant.id}
        )
      end
    end

    test "names the entries that are not addresses and creates nothing", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view |> element("button", "New poll") |> render_click()
      view |> element("button", "Add time") |> render_click()
      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      html =
        view
        |> form("form[phx-submit='create_poll']", %{
          "poll" => %{
            "title" => "Launch planning",
            "slots" => %{"0" => "#{date}T09:00"},
            "invitees" => "ada@example.com, not-an-address"
          }
        })
        |> render_submit(%{"poll" => %{"duration" => "30", "timezone" => "Europe/Tallinn"}})

      assert html =~ "Not valid email addresses: not-an-address"
      assert Polls.list_polls(user.id) == []
    end

    test "names the invitee names that can't be used and creates nothing", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view |> element("button", "New poll") |> render_click()
      view |> element("button", "Add time") |> render_click()
      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      view
      |> form("form[phx-submit='create_poll']", %{
        "poll" => %{
          "title" => "Launch planning",
          "slots" => %{"0" => "#{date}T09:00"},
          "invitees" => "ada@example.com, A <a@example.com>"
        }
      })
      |> render_submit(%{"poll" => %{"duration" => "30", "timezone" => "Europe/Tallinn"}})

      assert has_element?(view, "[data-testid='poll-invitees']", "These names can't be used: A")
      assert Polls.list_polls(user.id) == []
    end

    test "warns about a candidate time inside time off without refusing the poll", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      day_off = Date.add(Date.utc_today(), 7)
      insert(:time_off_period, profile: profile, starts_on: day_off, ends_on: day_off)
      working_day = day_off |> Date.add(1) |> Date.to_iso8601()

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      view |> element("button", "New poll") |> render_click()
      view |> element("button", "Add time") |> render_click()
      view |> element("button", "Add time") |> render_click()

      params = %{
        "poll" => %{
          "title" => "Offsite",
          "duration" => "30",
          "timezone" => profile.timezone,
          "slots" => %{"0" => "#{Date.to_iso8601(day_off)}T10:00", "1" => "#{working_day}T10:00"}
        }
      }

      view |> form("form[phx-submit='create_poll']", params) |> render_change()

      # Only the first row, the one on the day off, carries the warning.
      assert view
             |> element("[data-testid='poll-slot-time-off-warning'][data-slot-key='0']")
             |> render() =~ "This time falls within your time off"

      refute has_element?(view, "[data-testid='poll-slot-time-off-warning'][data-slot-key='1']")

      view |> form("form[phx-submit='create_poll']", params) |> render_submit()

      assert [poll] = Polls.list_polls(user.id)
      assert length(poll.time_slots) == 2
    end

    test "shows an error and creates nothing when submitted with no slots", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view |> element("button", "New poll") |> render_click()

      html =
        view
        |> form("form[phx-submit='create_poll']", %{"poll" => %{"title" => "Empty poll"}})
        |> render_submit(%{"poll" => %{"duration" => "30", "timezone" => "Europe/Tallinn"}})

      assert html =~ "Add at least one candidate time"
      assert Polls.list_polls(user.id) == []
    end

    # A changeset refusal reaches the form in the host's language, like the
    # form's own copy around it.
    test "shows a refused title in the host's language", %{conn: conn, user: user} do
      user |> Changeset.change(locale: "de") |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      view |> element("button[phx-click='new_poll']") |> render_click()
      view |> element("button[phx-click='add_slot']") |> render_click()

      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      view
      |> form("form[phx-submit='create_poll']", %{
        "poll" => %{"title" => "", "slots" => %{"0" => "#{date}T09:00"}}
      })
      |> render_submit(%{"poll" => %{"duration" => "30", "timezone" => "Europe/Tallinn"}})

      assert has_element?(view, "form[phx-submit='create_poll']", "darf nicht leer sein")
      assert Polls.list_polls(user.id) == []
    end
  end

  # ===========================================================================
  # Picking candidate times from the week
  # ===========================================================================

  describe "Picking candidate times from the week" do
    setup :setup_host

    setup %{user: user} do
      # Tomorrow, 10:00 to 11:00 UTC, in a calendar of the host's.
      day = Date.add(Date.utc_today(), 1)

      insert(:provider_calendar_event,
        calendar_integration: insert(:calendar_integration, user: user),
        start_at: DateTime.new!(day, ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(day, ~T[11:00:00], "Etc/UTC")
      )

      # Picking a time runs the clash check, which asks the provider.
      TestMocks.setup_calendar_mocks()

      %{day: Date.to_iso8601(day)}
    end

    defp open_form(conn) do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      view |> element("button", "New poll") |> render_click()
      # Abidjan keeps UTC all year, so the grid reads as the event does.
      change_form(view, %{"timezone" => "Africa/Abidjan", "duration" => "30"})
      view
    end

    defp change_form(view, params) do
      {selects, fields} = Map.split(params, ~w(timezone duration meeting_type_id))

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => fields})
      |> render_change(%{"poll" => selects})

      render_async(view)
    end

    defp status(view, at) do
      view
      |> element("[data-testid='poll-availability-week'] button[data-at='#{at}']")
      |> render()
      |> then(&Regex.run(~r/data-status="([a-z_]*)"/, &1, capture: :all_but_first))
      |> List.first()
    end

    test "shows the host busy where a meeting of the poll's length would clash",
         %{conn: conn, day: day} do
      view = open_form(conn)

      assert status(view, "#{day}T10:00") == "busy"
      assert status(view, "#{day}T10:30") == "busy"
      assert status(view, "#{day}T11:00") == "free"
      assert status(view, "#{day}T09:30") == "free"

      # An hour-long meeting at 09:30 would run into the event.
      change_form(view, %{"duration" => "60"})
      assert status(view, "#{day}T09:30") == "busy"
    end

    test "draws the week in the poll's timezone", %{conn: conn, day: day} do
      view = open_form(conn)
      change_form(view, %{"timezone" => "Asia/Kolkata"})

      # 10:00 UTC is 15:30 in Kolkata, which keeps no daylight saving time.
      assert status(view, "#{day}T15:30") == "busy"
      assert status(view, "#{day}T10:00") == "free"
    end

    test "adds a clicked time as a candidate, and removes it on a second click",
         %{conn: conn, day: day} do
      view = open_form(conn)
      cell = "[data-testid='poll-availability-week'] button[data-at='#{day}T14:00']"

      view |> element(cell) |> render_click()
      render_async(view)
      assert has_element?(view, "input[type='datetime-local'][value='#{day}T14:00']")
      assert has_element?(view, cell <> "[aria-pressed='true']")

      view |> element(cell) |> render_click()
      render_async(view)
      refute has_element?(view, "input[type='datetime-local'][value='#{day}T14:00']")
    end

    test "judges a duration still being typed as one step rather than failing",
         %{conn: conn, day: day} do
      view = open_form(conn)
      change_form(view, %{"duration" => "0"})

      assert status(view, "#{day}T10:30") == "busy"
      assert status(view, "#{day}T09:30") == "free"
    end

    test "removes a candidate typed off the half hour from the step it shows on",
         %{conn: conn, day: day} do
      view = open_form(conn)
      view |> element("button", "Add time") |> render_click()
      change_form(view, %{"slots" => %{"0" => "#{day}T14:15"}})

      cell = "[data-testid='poll-availability-week'] button[data-at='#{day}T14:00']"
      assert has_element?(view, cell <> "[aria-pressed='true']")

      view |> element(cell) |> render_click()
      render_async(view)

      refute has_element?(view, "input[type='datetime-local'][value='#{day}T14:15']")
      refute has_element?(view, "input[type='datetime-local'][value='#{day}T14:00']")
    end

    # Tonga is always a day ahead of Pago Pago, so whatever the host's own
    # clock reads, one of the two is on a different date from it.
    test "opens the week on today in the poll's timezone when it changes", %{conn: conn} do
      view = open_form(conn)

      for zone <- ["Pacific/Tongatapu", "Pacific/Pago_Pago"] do
        change_form(view, %{"timezone" => zone})
        today = zone |> DateTime.now!() |> DateTime.to_date()

        assert has_element?(view, "button[data-at='#{today}T12:00']")
        refute has_element?(view, "button[data-at='#{Date.add(today, -1)}T12:00']")
      end
    end

    test "widens the hours shown to take in a late candidate", %{conn: conn, day: day} do
      view = open_form(conn)
      refute has_element?(view, "button[data-at='#{day}T21:00']")

      view |> element("button", "Add time") |> render_click()
      change_form(view, %{"slots" => %{"0" => "#{day}T21:00"}})

      assert has_element?(view, "button[data-at='#{day}T21:00'][aria-pressed='true']")
    end

    test "marks where voting closes", %{conn: conn, day: day} do
      view = open_form(conn)
      refute has_element?(view, "[data-testid='poll-deadline-marker']")

      change_form(view, %{"deadline" => "#{day}T09:15"})

      assert has_element?(
               view,
               "button[data-at='#{day}T09:00'] [data-testid='poll-deadline-marker']"
             )
    end
  end

  # ===========================================================================
  # Updates on new votes
  # ===========================================================================

  describe "Updates on new votes" do
    setup :setup_host

    test "are on for a new poll unless the host unticks them", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      for {title, notify} <- [{"With updates", nil}, {"Quiet", "false"}] do
        view |> element("button", "New poll") |> render_click()
        view |> element("button", "Add time") |> render_click()

        params =
          %{
            "title" => title,
            "duration" => "30",
            "timezone" => "Europe/Tallinn",
            "slots" => %{"0" => "#{date}T09:00"}
          }

        params = if notify, do: Map.put(params, "notify_on_vote", notify), else: params

        view |> form("form[phx-submit='create_poll']", %{"poll" => params}) |> render_submit()
      end

      polls = Map.new(Polls.list_polls(user.id), &{&1.title, &1.notify_on_vote})
      assert polls == %{"With updates" => true, "Quiet" => false}
    end

    test "can be turned off while editing an open poll", %{conn: conn, user: user} do
      TestMocks.setup_calendar_mocks(events: [])
      poll = insert(:poll, user: user, status: :open, notify_on_vote: true, meeting_type_id: nil)
      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view
      |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
      |> render_click()

      view |> element("[data-testid='poll-edit-details']") |> render_click()

      view
      |> form("[data-testid='poll-details-form']",
        poll: %{title: poll.title, notify_on_vote: "false"}
      )
      |> render_submit()

      assert {:ok, %{notify_on_vote: false}} = Polls.get_poll_for_host(poll.id, user.id)
    end
  end

  # ===========================================================================
  # Share link gating
  # ===========================================================================

  describe "Share link" do
    test "is disabled with a connect-calendar tooltip when the host has no calendar", %{
      conn: conn
    } do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      insert(:profile, user: user, username: "hostwithout")
      insert(:poll, user: user, title: "Needs a calendar")

      {:ok, view, html} = live(log_in(conn, user), ~p"/dashboard/polls")

      refute html =~ ~s(phx-hook="CopyOnClick")

      # Inert but focusable: the accessible name stays the action and the
      # tooltip carries the reason.
      assert has_element?(
               view,
               ~s(button[aria-disabled="true"][aria-label="Copy poll link to clipboard"][aria-describedby$="-tip"])
             )

      assert has_element?(
               view,
               ~s([role="tooltip"]),
               "Connect a calendar in Calendar settings to enable this feature"
             )

      refute has_element?(view, ~s(button[aria-label="Copy poll link to clipboard"][disabled]))
    end

    test "is enabled when the host has an active calendar integration", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      insert(:profile, user: user, username: "hostwith")
      insert(:calendar_integration, user: user, is_active: true)
      poll = insert(:poll, user: user, title: "Ready to share")

      {:ok, _view, html} = live(log_in(conn, user), ~p"/dashboard/polls")

      assert html =~ ~s(phx-hook="CopyOnClick")
      assert html =~ "/hostwith/poll/#{poll.token}"
    end
  end
end
