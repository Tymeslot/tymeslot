defmodule Tymeslot.Emails.PollTemplatesTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.{
    PollDeadlineReminder,
    PollHostNudge,
    PollParticipantLink,
    PollVoteReceipt
  }

  alias Tymeslot.Repo

  import Tymeslot.Factory

  describe "PollDeadlineReminder.render/3" do
    setup do
      poll =
        insert(:poll,
          title: "Sprint Planning",
          deadline_at: DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second),
          timezone: "Europe/Berlin"
        )

      participant =
        insert(:poll_participant,
          poll: poll,
          name: "Dana Participant",
          email: "dana@example.com",
          timezone: "America/New_York",
          locale: "en"
        )

      %{poll: poll, participant: participant, voting_url: "https://tymeslot.app/p/vote-token-123"}
    end

    test "renders a Swoosh email with non-empty subject, html and text bodies", %{
      poll: poll,
      participant: participant,
      voting_url: url
    } do
      email = PollDeadlineReminder.render(poll, participant, url)

      assert %Swoosh.Email{} = email
      assert is_binary(email.subject) and email.subject != ""
      assert is_binary(email.html_body) and email.html_body != ""
      assert is_binary(email.text_body) and email.text_body != ""
    end

    test "subject references the poll title", %{
      poll: poll,
      participant: participant,
      voting_url: url
    } do
      email = PollDeadlineReminder.render(poll, participant, url)

      assert email.subject =~ poll.title
    end

    test "html and text bodies both contain the poll title and voting URL", %{
      poll: poll,
      participant: participant,
      voting_url: url
    } do
      email = PollDeadlineReminder.render(poll, participant, url)

      assert email.html_body =~ poll.title
      assert email.html_body =~ url
      assert email.text_body =~ poll.title
      assert email.text_body =~ url
    end

    test "addresses the participant", %{poll: poll, participant: participant, voting_url: url} do
      email = PollDeadlineReminder.render(poll, participant, url)

      assert email.to == [{participant.name, participant.email}]
    end

    test "names the host in the body", %{poll: poll, participant: participant, voting_url: url} do
      email = PollDeadlineReminder.render(poll, participant, url)

      assert email.html_body =~ poll.user.name
    end

    test "renders for a German-locale participant without raising", %{poll: poll, voting_url: url} do
      participant = insert(:poll_participant, poll: poll, locale: "de")

      email = PollDeadlineReminder.render(poll, participant, url)

      assert %Swoosh.Email{} = email
      assert email.html_body =~ poll.title
      assert email.html_body =~ url
      assert email.text_body =~ url
    end

    test "renders when the poll has no deadline", %{participant: participant, voting_url: url} do
      poll = insert(:poll, title: "Open Ended", deadline_at: nil)

      email = PollDeadlineReminder.render(poll, participant, url)

      assert %Swoosh.Email{} = email
      assert email.html_body =~ "Open Ended"
      assert email.text_body =~ url
    end

    test "replies to the poll's host, from the instance's address", %{
      participant: participant,
      voting_url: url
    } do
      host = insert(:user, name: "Hana Host", email: "hana@example.com")
      poll = insert(:poll, user: host)

      email = PollDeadlineReminder.render(poll, participant, url)

      assert email.reply_to == {"Hana Host", "hana@example.com"}
      assert email.from == {"Hana Host", Application.get_env(:tymeslot, :email)[:from_email]}
    end
  end

  describe "PollHostNudge.render/3" do
    setup do
      poll = insert(:poll, title: "Quarterly Review")
      %{poll: poll, results_url: "https://tymeslot.app/dashboard/polls/#{poll.id}"}
    end

    test "is written in the host's own language" do
      host = insert(:user, locale: "de")
      poll = insert(:poll, title: "Quarterly Review", user: host)

      email = PollHostNudge.render(poll, :all_voted, "https://tymeslot.app/dashboard/polls/1")

      assert email.html_body =~ "Alle haben zu Quarterly Review abgestimmt"
    end

    test "all_voted renders a complete email containing the poll title and results URL", %{
      poll: poll,
      results_url: url
    } do
      email = PollHostNudge.render(poll, :all_voted, url)

      assert %Swoosh.Email{} = email
      assert is_binary(email.subject) and email.subject != ""
      assert email.html_body =~ poll.title
      assert email.html_body =~ url
      assert email.text_body =~ poll.title
      assert email.text_body =~ url
    end

    test "deadline_passed renders a complete email containing the poll title and results URL", %{
      poll: poll,
      results_url: url
    } do
      email = PollHostNudge.render(poll, :deadline_passed, url)

      assert %Swoosh.Email{} = email
      assert is_binary(email.subject) and email.subject != ""
      assert email.html_body =~ poll.title
      assert email.html_body =~ url
      assert email.text_body =~ poll.title
      assert email.text_body =~ url
    end

    test "the two variants produce distinct subjects and bodies", %{poll: poll, results_url: url} do
      all_voted = PollHostNudge.render(poll, :all_voted, url)
      deadline_passed = PollHostNudge.render(poll, :deadline_passed, url)

      assert all_voted.subject != deadline_passed.subject
      assert all_voted.html_body != deadline_passed.html_body
      assert all_voted.text_body != deadline_passed.text_body
    end

    test "addresses the host", %{poll: poll, results_url: url} do
      email = PollHostNudge.render(poll, :all_voted, url)

      assert email.to == [{poll.user.name, poll.user.email}]
    end
  end

  describe "PollParticipantLink.render/3" do
    setup do
      poll =
        insert(:poll,
          title: "Sprint Planning",
          deadline_at: DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second),
          timezone: "Europe/Berlin"
        )

      participant =
        insert(:poll_participant,
          poll: poll,
          name: "<b>Whatever Someone Typed</b>",
          email: "dana@example.com",
          locale: "en",
          confirmed_at: nil
        )

      %{poll: poll, participant: participant, url: "https://tymeslot.app/h/poll/t?p=personal-123"}
    end

    test "carries the link and the poll title in both bodies", %{
      poll: poll,
      participant: participant,
      url: url
    } do
      email = PollParticipantLink.render(poll, participant, url)

      assert email.subject =~ poll.title
      assert email.html_body =~ poll.title
      assert email.html_body =~ url
      assert email.text_body =~ poll.title
      assert email.text_body =~ url
      assert email.text_body =~ "Voting closes"
    end

    test "names nobody but the host, so a stranger's typing never reaches the inbox", %{
      poll: poll,
      participant: participant,
      url: url
    } do
      email = PollParticipantLink.render(poll, participant, url)

      assert email.to == [{"", "dana@example.com"}]
      refute email.html_body =~ "Whatever Someone Typed"
      refute email.text_body =~ "Whatever Someone Typed"
      assert email.text_body =~ "ignore this email"
    end
  end

  describe "PollVoteReceipt.render/3" do
    test "lists each time with the participant's answer and carries the link" do
      poll = insert(:poll, title: "Sprint Planning", timezone: "Etc/UTC")
      start_time = ~U[2030-03-04 10:00:00Z]

      slot_a =
        insert(:poll_time_slot,
          poll: poll,
          start_time: start_time,
          end_time: DateTime.add(start_time, 1, :hour),
          position: 0
        )

      slot_b =
        insert(:poll_time_slot,
          poll: poll,
          start_time: DateTime.add(start_time, 1, :day),
          end_time: DateTime.add(start_time, 25, :hour),
          position: 1
        )

      participant = insert(:poll_participant, poll: poll, name: "Dana", email: "dana@example.com")
      insert(:poll_vote, participant: participant, time_slot: slot_a, response: :if_need_be)
      insert(:poll_vote, participant: participant, time_slot: slot_b, response: :no)

      poll = Repo.preload(poll, [:time_slots, user: :profile])
      participant = Repo.preload(participant, :votes)
      url = "https://tymeslot.app/h/poll/t?p=personal-123"

      email = PollVoteReceipt.render(poll, participant, url)

      assert email.to == [{"Dana", "dana@example.com"}]
      assert email.subject =~ poll.title
      assert email.text_body =~ url
      assert email.html_body =~ url
      assert email.text_body =~ ": If need be"
      assert email.text_body =~ ": No"
    end
  end
end
