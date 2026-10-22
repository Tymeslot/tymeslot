defmodule TymeslotWeb.Dashboard.PollsTest do
  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  # A host with a profile but no calendar integration and no username: the
  # baseline for list/create/validation tests.
  defp setup_host(_context) do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    profile = insert(:profile, user: user)
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
          "duration" => "30",
          "timezone" => "Europe/Tallinn",
          "slots" => %{"0" => "#{date}T09:00", "1" => "#{date}T10:00"}
        }
      })
      |> render_submit()

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
          "duration" => "30",
          "timezone" => "Europe/Tallinn",
          "slots" => %{"0" => "#{date}T09:00"},
          "invitees" => "Grace Hopper <grace@example.com>, ada@example.com"
        }
      })
      |> render_submit()

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
            "duration" => "30",
            "timezone" => "Europe/Tallinn",
            "slots" => %{"0" => "#{date}T09:00"},
            "invitees" => "ada@example.com, not-an-address"
          }
        })
        |> render_submit()

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
          "duration" => "30",
          "timezone" => "Europe/Tallinn",
          "slots" => %{"0" => "#{date}T09:00"},
          "invitees" => "ada@example.com, A <a@example.com>"
        }
      })
      |> render_submit()

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
        |> form("form[phx-submit='create_poll']", %{
          "poll" => %{
            "title" => "Empty poll",
            "duration" => "30",
            "timezone" => "Europe/Tallinn"
          }
        })
        |> render_submit()

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
        "poll" => %{
          "title" => "",
          "duration" => "30",
          "timezone" => "Europe/Tallinn",
          "slots" => %{"0" => "#{date}T09:00"}
        }
      })
      |> render_submit()

      assert has_element?(view, "form[phx-submit='create_poll']", "darf nicht leer sein")
      assert Polls.list_polls(user.id) == []
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
  describe "Who can vote" do
    setup :setup_host

    defp open_create_form(view) do
      view |> element("button", "New poll") |> render_click()
      view |> element("button", "Add time") |> render_click()
      view
    end

    defp create_params(extra) do
      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      Map.merge(
        %{
          "title" => "Launch planning",
          "duration" => "30",
          "timezone" => "Europe/Tallinn",
          "slots" => %{"0" => "#{date}T09:00"}
        },
        extra
      )
    end

    test "a new poll is open to anyone with the link while nobody is invited", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)

      assert has_element?(view, "input[name='poll[access]'][value='anyone'][checked]")

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => create_params(%{})})
      |> render_submit()

      assert [%{invite_only: false}] = Polls.list_polls(user.id)
    end

    test "inviting people with a new poll presets it to invited people only", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)
      params = create_params(%{"invitees" => "grace@example.com"})

      view |> form("form[phx-submit='create_poll']", %{"poll" => params}) |> render_change()

      assert has_element?(view, "input[name='poll[access]'][value='invited'][checked]")

      view |> form("form[phx-submit='create_poll']", %{"poll" => params}) |> render_submit()

      assert [%{invite_only: true}] = Polls.list_polls(user.id)
    end

    test "the host can keep a poll with invitees open to anyone", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)
      params = create_params(%{"invitees" => "grace@example.com"})

      view |> form("form[phx-submit='create_poll']", %{"poll" => params}) |> render_change()

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => Map.put(params, "access", "anyone")})
      |> render_change()

      assert has_element?(view, "input[name='poll[access]'][value='anyone'][checked]")

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => Map.put(params, "access", "anyone")})
      |> render_submit()

      assert [%{invite_only: false}] = Polls.list_polls(user.id)
    end

    test "submitting invitees without a preceding change still creates an invite-only poll", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)
      params = create_params(%{"invitees" => "grace@example.com"})

      view |> form("form[phx-submit='create_poll']", %{"poll" => params}) |> render_submit()

      assert [%{invite_only: true}] = Polls.list_polls(user.id)
    end

    test "clearing the invitees flips an unchosen preset back to anyone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)
      params = create_params(%{"invitees" => "grace@example.com"})

      view |> form("form[phx-submit='create_poll']", %{"poll" => params}) |> render_change()
      assert has_element?(view, "input[name='poll[access]'][value='invited'][checked]")

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => Map.put(params, "invitees", "")})
      |> render_change()

      assert has_element?(view, "input[name='poll[access]'][value='anyone'][checked]")
    end

    test "clearing the invitees keeps an explicit choice", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)
      params = create_params(%{"invitees" => "grace@example.com", "access" => "invited"})

      view |> form("form[phx-submit='create_poll']", %{"poll" => params}) |> render_change()

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => Map.put(params, "invitees", "")})
      |> render_change()

      assert has_element?(view, "input[name='poll[access]'][value='invited'][checked]")
    end

    test "the withdraw hint counts requests that arrive while the editor is open", %{
      conn: conn,
      user: user
    } do
      TestMocks.setup_calendar_mocks(events: [])
      poll = insert(:poll, user: user, status: :open, meeting_type_id: nil, invite_only: false)
      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view
      |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
      |> render_click()

      view |> element("[data-testid='poll-edit-details']") |> render_click()

      # Inserted after the editor opened; nothing broadcasts a link request.
      insert(:poll_participant,
        poll: poll,
        confirmed_at: nil,
        link_sent_at: DateTime.utc_now(:second)
      )

      view
      |> form("[data-testid='poll-details-form']", poll: %{title: poll.title, access: "invited"})
      |> render_change()

      assert has_element?(view, "[data-testid='poll-access-hint']", "1 person")
    end

    test "choosing invited people with nobody invited says nobody can vote yet", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      open_create_form(view)

      view
      |> form("form[phx-submit='create_poll']", %{
        "poll" => create_params(%{"access" => "invited"})
      })
      |> render_change()

      assert has_element?(view, "[data-testid='poll-access-hint']", "Nobody can vote")
    end

    test "switching an open poll to invited people only withdraws pending requests", %{
      conn: conn,
      user: user
    } do
      TestMocks.setup_calendar_mocks(events: [])
      poll = insert(:poll, user: user, status: :open, meeting_type_id: nil, invite_only: false)
      insert(:poll_time_slot, poll: poll)
      now = DateTime.utc_now(:second)
      pending = insert(:poll_participant, poll: poll, confirmed_at: nil, link_sent_at: now)
      voter = insert(:poll_participant, poll: poll, confirmed_at: now, voted_at: now)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view
      |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
      |> render_click()

      view |> element("[data-testid='poll-edit-details']") |> render_click()

      view
      |> form("[data-testid='poll-details-form']", poll: %{title: poll.title, access: "invited"})
      |> render_change()

      assert has_element?(view, "[data-testid='poll-access-hint']", "1 person")

      view
      |> form("[data-testid='poll-details-form']", poll: %{title: poll.title, access: "invited"})
      |> render_submit()

      assert {:ok, %{invite_only: true}} = Polls.get_poll_for_host(poll.id, user.id)
      assert Repo.get(PollParticipantSchema, pending.id) == nil
      assert Repo.get(PollParticipantSchema, voter.id)
      assert has_element?(view, "[data-testid='poll-access-mode']", "Only invited people")
    end

    test "the results panel names who can vote", %{conn: conn, user: user} do
      TestMocks.setup_calendar_mocks(events: [])
      poll = insert(:poll, user: user, status: :open, meeting_type_id: nil, invite_only: false)
      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")

      view
      |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
      |> render_click()

      assert has_element?(view, "[data-testid='poll-access-mode']", "Anyone with the link")
    end
  end

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
               ~s(button[aria-disabled="true"][aria-label="Copy poll link to clipboard"]) <>
                 ~s([title="Connect a calendar in Calendar settings to enable this feature"])
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
