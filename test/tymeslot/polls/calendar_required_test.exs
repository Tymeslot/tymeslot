defmodule Tymeslot.Polls.CalendarRequiredTest do
  @moduledoc """
  Guests vote on a public page that opens only once the host has a calendar
  connected, so a host without one can neither create a poll nor email
  anyone a link to it: refused up front, before anything is written or
  queued.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :polls

  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantQueries
  alias Tymeslot.Workers.EmailWorker

  setup do
    user = insert(:user)
    insert(:profile, user: user)

    start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

    attrs = %{
      title: "Team sync",
      duration_minutes: 30,
      timezone: "Etc/UTC",
      slots: [%{start_time: start_time}]
    }

    %{user: user, attrs: attrs}
  end

  describe "create_poll/2" do
    test "refuses a host without a calendar and creates nothing", %{user: user, attrs: attrs} do
      assert {:error, :no_calendar} =
               Polls.create_poll(user.id, Map.put(attrs, :invitees, [%{email: "a@example.com"}]))

      assert Polls.list_polls(user.id) == []
      assert all_enqueued(worker: EmailWorker) == []
    end

    test "refuses a host whose only calendar is a read-only feed", %{user: user, attrs: attrs} do
      insert(:calendar_integration, user: user, provider: "ics_url")

      assert {:error, :no_calendar} = Polls.create_poll(user.id, attrs)
    end

    test "creates the poll once a calendar is connected", %{user: user, attrs: attrs} do
      insert(:calendar_integration, user: user, provider: "debug")

      assert {:ok, poll} = Polls.create_poll(user.id, attrs)
      assert [%{id: id}] = Polls.list_polls(user.id)
      assert id == poll.id
    end
  end

  describe "invite_participants/3" do
    test "refuses to invite anyone once the calendar is gone", %{user: user} do
      poll = insert(:poll, user: user)

      assert {:error, :no_calendar} =
               Polls.invite_participants(poll.id, user.id, [%{email: "a@example.com", name: nil}])

      assert PollParticipantQueries.get_by_poll_and_email(poll.id, "a@example.com") == nil
      assert all_enqueued(worker: EmailWorker) == []
    end
  end

  describe "resend_invitation/3" do
    test "refuses to send a link again once the calendar is gone", %{user: user} do
      poll = insert(:poll, user: user)
      now = DateTime.utc_now(:second)

      participant =
        insert(:poll_participant,
          poll: poll,
          email: "ada@example.com",
          invited_at: now,
          confirmed_at: now,
          link_sent_at: DateTime.add(now, -1, :day)
        )

      assert {:error, :no_calendar} = Polls.resend_invitation(poll.id, user.id, participant.id)
      assert all_enqueued(worker: EmailWorker) == []
    end
  end
end
