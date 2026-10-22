defmodule TymeslotWeb.Dashboard.PollManagementTest do
  @moduledoc """
  Covers managing a poll from the dashboard: choosing its reminders, editing
  an open poll (deadline, reminders, new times), taking someone off it, and
  deleting a poll that is over.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :polls
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollParticipantSchema, PollSchema}
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup %{conn: conn} do
    TestMocks.setup_calendar_mocks(events: [])

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, username: "managehost", timezone: "Etc/UTC")
    insert(:calendar_integration, user: user, is_active: true)

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user}
  end

  describe "reminders in the create form" do
    test "appear once someone is invited, a day before the deadline", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      view |> element("button", "New poll") |> render_click()
      view |> element("button", "Add time") |> render_click()

      refute has_element?(view, "[data-testid='poll-reminders-form']")

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => %{"invitees" => "ada@example.com"}})
      |> render_change()

      assert has_element?(
               view,
               "[data-testid='poll-reminders-form']",
               "Reminders go to invited people who haven't voted yet."
             )

      assert has_element?(view, "[data-testid='poll-reminders-form']", "1 day before")
      view |> element("[data-testid='reminder-preset-3-days']") |> render_click()

      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()
      deadline = Date.utc_today() |> Date.add(5) |> Date.to_iso8601()

      view
      |> form("form[phx-submit='create_poll']", %{
        "poll" => %{
          "title" => "Offsite",
          "duration" => "30",
          "timezone" => "Europe/Berlin",
          "deadline" => "#{deadline}T12:00",
          "invitees" => "ada@example.com",
          "slots" => %{"0" => "#{date}T09:00"}
        }
      })
      |> render_submit()

      assert [poll] = Polls.list_polls(user.id)

      assert PollSchema.reminders(poll) == [
               %{value: 1, unit: "days"},
               %{value: 3, unit: "days"}
             ]
    end

    test "saves a custom reminder typed but never added", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      view |> element("button", "New poll") |> render_click()
      view |> element("button", "Add time") |> render_click()

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => %{"invitees" => "ada@example.com"}})
      |> render_change()

      view |> element("[data-testid='reminder-custom-toggle']") |> render_click()

      view
      |> element("[data-testid='poll-reminders-form']")
      |> render_change(%{"reminder" => %{"value" => "2", "unit" => "days"}})

      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()
      deadline = Date.utc_today() |> Date.add(5) |> Date.to_iso8601()

      view
      |> form("form[phx-submit='create_poll']", %{
        "poll" => %{
          "title" => "Offsite",
          "duration" => "30",
          "timezone" => "Europe/Berlin",
          "deadline" => "#{deadline}T12:00",
          "invitees" => "ada@example.com",
          "slots" => %{"0" => "#{date}T09:00"}
        }
      })
      |> render_submit()

      assert [poll] = Polls.list_polls(user.id)
      assert %{value: 2, unit: "days"} in PollSchema.reminders(poll)
    end

    test "a bad custom reminder left in the hidden picker does not block the save", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      view |> element("button", "New poll") |> render_click()
      view |> element("button", "Add time") |> render_click()

      view
      |> form("form[phx-submit='create_poll']", %{"poll" => %{"invitees" => "ada@example.com"}})
      |> render_change()

      view |> element("[data-testid='reminder-custom-toggle']") |> render_click()

      view
      |> element("[data-testid='poll-reminders-form']")
      |> render_change(%{"reminder" => %{"value" => "0", "unit" => "days"}})

      # Clearing the invitees hides the picker, with its invalid value still in it.
      view
      |> form("form[phx-submit='create_poll']", %{"poll" => %{"invitees" => ""}})
      |> render_change()

      refute has_element?(view, "[data-testid='poll-reminders-form']")

      date = Date.utc_today() |> Date.add(7) |> Date.to_iso8601()

      view
      |> form("form[phx-submit='create_poll']", %{
        "poll" => %{
          "title" => "Offsite",
          "duration" => "30",
          "timezone" => "Europe/Berlin",
          "invitees" => "",
          "slots" => %{"0" => "#{date}T09:00"}
        }
      })
      |> render_submit()

      assert [%{title: "Offsite"}] = Polls.list_polls(user.id)
    end
  end

  describe "editing an open poll" do
    setup %{user: user} do
      poll =
        insert(:poll,
          user: user,
          status: :open,
          title: "Offsite",
          timezone: "Etc/UTC",
          duration_minutes: 30,
          meeting_type_id: nil,
          deadline_at: in_days(3)
        )

      insert(:poll_time_slot, poll: poll, start_time: in_days(7), position: 0)
      %{poll: poll}
    end

    test "moves the deadline, changes the reminders and adds a time", %{
      conn: conn,
      user: user,
      poll: poll
    } do
      insert_invitee(poll)
      view = open_editor(conn, poll)

      view |> element("[data-testid='reminder-preset-3-days']") |> render_click()
      view |> element("[data-testid='poll-new-times'] button", "Add time") |> render_click()

      view
      |> form("[data-testid='poll-details-form']", %{
        "poll" => %{
          "title" => "Offsite",
          "deadline" => local(in_days(5)),
          "new_times" => %{"0" => local(in_days(9))}
        }
      })
      |> render_submit()

      {:ok, updated} = Polls.get_poll_for_host(poll.id, user.id)
      assert DateTime.compare(updated.deadline_at, in_days(4)) == :gt
      assert length(updated.time_slots) == 2

      assert PollSchema.reminders(updated) == [
               %{value: 1, unit: "days"},
               %{value: 3, unit: "days"}
             ]

      refute has_element?(view, "[data-testid='poll-details-form']")
    end

    test "sets a meeting type the host made after sending the poll", %{
      conn: conn,
      user: user,
      poll: poll
    } do
      meeting_type = insert(:meeting_type, user: user, name: "Office hours", is_active: true)

      # With a meeting type set, the reloaded panel's conflict check reads that
      # type's calendar fresh.
      Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _id, _from, _to ->
        {:ok, []}
      end)

      view = open_editor(conn, poll)

      view
      |> form("[data-testid='poll-details-form']", %{
        "poll" => %{"title" => "Offsite", "meeting_type_id" => to_string(meeting_type.id)}
      })
      |> render_submit()

      assert Repo.get!(PollSchema, poll.id).meeting_type_id == meeting_type.id
    end

    test "keeps a meeting type switched off since the poll went out", %{
      conn: conn,
      user: user,
      poll: poll
    } do
      switched_off = insert(:meeting_type, user: user, name: "Old office hours", is_active: false)
      Repo.update!(Changeset.change(poll, meeting_type_id: switched_off.id))

      Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _id, _from, _to ->
        {:ok, []}
      end)

      view = open_editor(conn, poll)

      assert has_element?(
               view,
               "select[name='poll[meeting_type_id]'] option[selected][value='#{switched_off.id}']"
             )

      assert has_element?(view, "[data-testid='poll-kept-meeting-type']", "Old office hours")

      view
      |> form("[data-testid='poll-details-form']", %{"poll" => %{"title" => "Renamed"}})
      |> render_submit()

      saved = Repo.get!(PollSchema, poll.id)
      assert saved.title == "Renamed"
      assert saved.meeting_type_id == switched_off.id
    end

    test "keeps the editor open and explains a deadline in the past", %{conn: conn, poll: poll} do
      view = open_editor(conn, poll)

      html =
        view
        |> form("[data-testid='poll-details-form']", %{
          "poll" => %{"title" => "Offsite", "deadline" => local(in_days(-1))}
        })
        |> render_submit()

      assert html =~ "The deadline must be in the future"
      assert has_element?(view, "[data-testid='poll-details-form']")
    end

    test "takes someone off the poll after a confirmation", %{conn: conn, poll: poll} do
      participant = insert(:poll_participant, poll: poll, name: "Joker")
      view = open_editor(conn, poll)

      view |> element("[data-testid='poll-remove-participant']") |> render_click()

      assert has_element?(view, "#remove-participant-modal-#{poll.id}", "Joker")
      assert Repo.get(PollParticipantSchema, participant.id)

      view
      |> element(
        "#remove-participant-modal-#{poll.id} [data-testid='confirm-remove-participant']"
      )
      |> render_click()

      assert Repo.get(PollParticipantSchema, participant.id) == nil
      refute render(view) =~ "Joker"
    end

    test "keeps someone when the host thinks better of it", %{conn: conn, poll: poll} do
      participant = insert(:poll_participant, poll: poll, name: "Joker")
      view = open_editor(conn, poll)

      view |> element("[data-testid='poll-remove-participant']") |> render_click()

      view
      |> element("#remove-participant-modal-#{poll.id} button", "Keep")
      |> render_click()

      refute has_element?(view, "#remove-participant-modal-#{poll.id}")
      assert Repo.get(PollParticipantSchema, participant.id)
    end

    test "says so when the person is already off the poll", %{conn: conn, poll: poll} do
      participant = insert(:poll_participant, poll: poll, name: "Joker")
      view = open_editor(conn, poll)

      view |> element("[data-testid='poll-remove-participant']") |> render_click()
      Repo.delete!(participant)

      view
      |> element(
        "#remove-participant-modal-#{poll.id} [data-testid='confirm-remove-participant']"
      )
      |> render_click()

      html = render(view)
      assert html =~ "They are no longer on this poll."
      refute html =~ "This poll is no longer open."
    end

    test "ignores a removal for someone not on the poll", %{conn: conn, poll: poll} do
      insert(:poll_participant, poll: poll, name: "Joker")
      view = open_editor(conn, poll)

      view
      |> element("[data-testid='poll-remove-participant']")
      |> render_click(%{"id" => "not-a-uuid"})

      refute has_element?(view, "#remove-participant-modal-#{poll.id}")
      assert has_element?(view, "[data-testid='poll-details-form']")
    end

    test "shows an error the editor cannot place on a field", %{conn: conn, poll: poll} do
      view = open_editor(conn, poll)
      Repo.delete!(poll)

      html =
        view
        |> form("[data-testid='poll-details-form']", %{"poll" => %{"title" => "Renamed"}})
        |> render_submit()

      assert html =~ "Couldn&#39;t save this poll. Please try again."
    end

    test "offers no reminders on a poll nobody was invited to", %{conn: conn, poll: poll} do
      view = open_editor(conn, poll)
      refute has_element?(view, "[data-testid='poll-reminders-form']")
    end

    test "offers reminders once someone is invited", %{conn: conn, poll: poll} do
      insert_invitee(poll)
      view = open_editor(conn, poll)

      assert has_element?(
               view,
               "[data-testid='poll-reminders-form']",
               "Reminders go to invited people who haven't voted yet."
             )
    end

    test "saves a custom reminder typed but never added", %{conn: conn, user: user, poll: poll} do
      insert_invitee(poll)
      view = open_editor(conn, poll)

      view |> element("[data-testid='reminder-custom-toggle']") |> render_click()

      view
      |> element("#poll-edit-reminders-#{poll.id}")
      |> render_change(%{"reminder" => %{"value" => "2", "unit" => "days"}})

      view
      |> form("[data-testid='poll-details-form']", %{"poll" => %{"title" => "Offsite"}})
      |> render_submit()

      {:ok, updated} = Polls.get_poll_for_host(poll.id, user.id)
      assert %{value: 2, unit: "days"} in PollSchema.reminders(updated)
    end

    test "keeps the editor open when the typed reminder is not valid", %{conn: conn, poll: poll} do
      insert_invitee(poll)
      view = open_editor(conn, poll)

      view |> element("[data-testid='reminder-custom-toggle']") |> render_click()

      view
      |> element("#poll-edit-reminders-#{poll.id}")
      |> render_change(%{"reminder" => %{"value" => "0", "unit" => "days"}})

      view
      |> form("[data-testid='poll-details-form']", %{"poll" => %{"title" => "Renamed"}})
      |> render_submit()

      assert has_element?(view, "[data-testid='poll-details-form']")
      assert Repo.get!(PollSchema, poll.id).title == "Offsite"
    end

    test "adds the typed reminder when focus leaves the custom row", %{conn: conn, poll: poll} do
      insert_invitee(poll)
      view = open_editor(conn, poll)

      view |> element("[data-testid='reminder-custom-toggle']") |> render_click()

      view
      |> element("#poll_reminder-custom-row")
      |> render_hook("poll_commit_custom_reminder", %{
        "reminder" => %{"value" => "4", "unit" => "days"}
      })

      assert has_element?(view, "[data-testid='poll-reminders-form']", "4 days before")
    end
  end

  describe "deleting a poll" do
    test "a poll that is over is deleted after a confirmation", %{conn: conn, user: user} do
      poll = insert(:poll, user: user, status: :cancelled, title: "Old test poll")
      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      view |> element("[data-testid='poll-delete']") |> render_click()
      view |> element("#delete-poll-modal [data-testid='confirm-delete-poll']") |> render_click()

      assert Polls.list_polls(user.id) == []
      refute render(view) =~ "Old test poll"
    end

    test "an open poll offers no delete, only cancelling", %{conn: conn, user: user} do
      poll = insert(:poll, user: user, status: :open)
      insert(:poll_time_slot, poll: poll)

      {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
      select_poll(view, poll)

      refute has_element?(view, "[data-testid='poll-delete']")
      assert has_element?(view, "button[phx-click='request_cancel_poll']")
    end
  end

  defp open_editor(conn, poll) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/polls")
    select_poll(view, poll)
    view |> element("[data-testid='poll-edit-details']") |> render_click()
    view
  end

  defp select_poll(view, poll) do
    view
    |> element("button[phx-click='select_poll'][phx-value-id='#{poll.id}']")
    |> render_click()
  end

  defp insert_invitee(poll) do
    now = DateTime.utc_now(:second)

    insert(:poll_participant,
      poll: poll,
      invited_at: now,
      confirmed_at: now,
      link_sent_at: now,
      voted_at: nil
    )
  end

  defp in_days(days), do: DateTime.add(DateTime.utc_now(:second), days, :day)

  defp local(datetime),
    do: datetime |> DateTime.to_naive() |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)
end
