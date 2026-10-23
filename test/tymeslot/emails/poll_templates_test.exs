defmodule Tymeslot.Emails.PollTemplatesTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.{
    PollDeadlineReminder,
    PollHostNudge,
    PollInvitation,
    PollParticipantLink,
    PollVoteDigest,
    PollVoteReceipt
  }

  alias Tymeslot.Mailer
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
      poll = :poll |> insert(title: "Quarterly Review") |> for_host_email()
      %{poll: poll, results_url: "https://tymeslot.app/dashboard/polls/#{poll.id}"}
    end

    test "is written in the host's own language" do
      host = insert(:user, locale: "de")
      poll = :poll |> insert(title: "Quarterly Review", user: host) |> for_host_email()

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

    test "carries no open tracking", %{poll: poll, results_url: url} do
      assert Mailer.tracking(PollHostNudge.render(poll, :all_voted, url)) == :transactional
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

    test "carries the standings, marking the time with the most votes", %{results_url: url} do
      poll = insert(:poll, title: "Quarterly Review", timezone: "Etc/UTC")
      start_time = ~U[2030-03-04 10:00:00Z]

      leading =
        insert(:poll_time_slot,
          poll: poll,
          start_time: start_time,
          end_time: DateTime.add(start_time, 1, :hour),
          position: 0
        )

      other =
        insert(:poll_time_slot,
          poll: poll,
          start_time: DateTime.add(start_time, 1, :day),
          end_time: DateTime.add(start_time, 25, :hour),
          position: 1
        )

      for response <- [:yes, :yes] do
        voter = insert(:poll_participant, poll: poll, voted_at: DateTime.utc_now(:second))
        insert(:poll_vote, participant: voter, time_slot: leading, response: response)
        insert(:poll_vote, participant: voter, time_slot: other, response: :if_need_be)
      end

      email = PollHostNudge.render(for_host_email(poll), :deadline_passed, url)

      assert email.text_body =~ "Current standings"
      assert email.text_body =~ ~r/★ .*: 2 yes, 0 if need be, 0 no \(most votes\)/
      assert email.text_body =~ ": 0 yes, 2 if need be, 0 no"
      refute email.text_body =~ ~r/★ .*: 0 yes/
      assert email.text_body =~ "2 people have voted so far."
      assert email.html_body =~ "most votes"
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

    test "tells someone yet to save responses that they count once saved", %{
      poll: poll,
      participant: participant,
      url: url
    } do
      email = PollParticipantLink.render(poll, participant, url)

      assert email.text_body =~ "Your responses count once you save them through it."
      assert email.text_body =~ "Nothing is recorded unless the link is used."
    end

    test "tells someone who already voted that their responses count", %{poll: poll, url: url} do
      voted_at = DateTime.utc_now(:second)

      voter =
        insert(:poll_participant,
          poll: poll,
          email: "returning@example.com",
          locale: "en",
          confirmed_at: voted_at,
          voted_at: voted_at
        )

      email = PollParticipantLink.render(poll, voter, url)

      for body <- [email.text_body, email.html_body] do
        assert body =~ "The responses you saved already count"
        assert body =~ "Your saved responses stay as they are."
        refute body =~ "count once you save them"
        refute body =~ "Nothing is recorded"
      end
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

  describe "PollVoteDigest.render/3" do
    test "names who voted, with the standings and a way to turn updates off" do
      host = insert(:user, locale: "en")
      poll = insert(:poll, title: "Quarterly Review", user: host, timezone: "Etc/UTC")
      start_time = ~U[2030-03-04 10:00:00Z]

      slot =
        insert(:poll_time_slot,
          poll: poll,
          start_time: start_time,
          end_time: DateTime.add(start_time, 1, :hour)
        )

      voters =
        for name <- ["Ada", "Grace"] do
          voter =
            insert(:poll_participant, poll: poll, name: name, voted_at: DateTime.utc_now(:second))

          insert(:poll_vote, participant: voter, time_slot: slot, response: :yes)
          voter
        end

      email =
        PollVoteDigest.render(
          for_host_email(poll),
          voters,
          "https://tymeslot.app/dashboard/polls"
        )

      assert email.to == [{host.name, host.email}]
      assert email.subject =~ "New responses on"
      assert email.subject =~ "Quarterly Review"
      assert email.text_body =~ "2 new responses on Quarterly Review"
      assert email.text_body =~ "Responses from: Ada, Grace"
      assert email.text_body =~ ": 2 yes, 0 if need be, 0 no"
      assert email.text_body =~ "turn them off"
      assert email.html_body =~ "https://tymeslot.app/dashboard/polls"
      # An update the host asked for, about their own poll: no open tracking.
      assert Mailer.tracking(email) == :transactional
    end
  end

  describe "PollInvitation.render/3" do
    setup do
      poll =
        insert(:poll,
          title: "Sprint Planning",
          description: "<script>alert(1)</script>Bring the roadmap.",
          timezone: "Europe/Berlin",
          deadline_at: ~U[2030-03-01 17:00:00Z]
        )

      start_time = ~U[2030-03-04 10:00:00Z]

      insert(:poll_time_slot,
        poll: poll,
        start_time: start_time,
        end_time: DateTime.add(start_time, 1, :hour)
      )

      poll = Repo.preload(poll, [:time_slots, user: :profile])
      url = "https://tymeslot.app/h/poll/t?p=personal-123"
      %{poll: poll, url: url}
    end

    test "keeps the line breaks the host wrote in their note", ctx do
      poll = %{ctx.poll | description: "Bring the roadmap.\nAnd <b>snacks</b>."}
      invitee = insert(:poll_participant, poll: ctx.poll, name: "Dana", email: "dana@example.com")

      email = PollInvitation.render(poll, invitee, ctx.url)

      assert email.html_body =~ ~r{Bring the roadmap\.<br\s*/?>And &lt;b&gt;snacks&lt;/b&gt;\.}
      assert email.text_body =~ "Bring the roadmap.\nAnd <b>snacks</b>."
    end

    test "carries the times in the invitee's zone, the deadline, the note and the link", ctx do
      invitee =
        insert(:poll_participant,
          poll: ctx.poll,
          name: nil,
          email: "dana@example.com",
          timezone: "Europe/Berlin"
        )

      email = PollInvitation.render(ctx.poll, invitee, ctx.url)

      assert email.to == [{"", "dana@example.com"}]
      assert email.subject =~ "Sprint Planning"
      assert email.html_body =~ ctx.url
      assert email.text_body =~ ctx.url
      # 10:00 UTC is 11:00 in Berlin in March.
      assert email.text_body =~ "11:00"
      assert email.text_body =~ "Voting closes"
      assert email.html_body =~ "Bring the roadmap."
      refute email.html_body =~ "<script>"
    end

    test "addresses an invitee by name when the host gave one", ctx do
      invitee = insert(:poll_participant, poll: ctx.poll, name: "Dana", email: "dana@example.com")

      assert PollInvitation.render(ctx.poll, invitee, ctx.url).to == [
               {"Dana", "dana@example.com"}
             ]
    end
  end

  defp for_host_email(poll),
    do: Repo.preload(poll, [:time_slots, user: :profile, participants: :votes])
end
