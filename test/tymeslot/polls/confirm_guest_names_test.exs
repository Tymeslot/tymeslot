defmodule Tymeslot.Polls.ConfirmGuestNamesTest do
  @moduledoc """
  The participants of a confirmed poll become the meeting's guests under the
  names they gave, so their emails, the host's email and the dashboard name
  them rather than show a bare address.
  """
  # Not async: the real email service is swapped in for the mock, and Swoosh
  # delivers to the test process through the shared-process setting.
  use Tymeslot.DataCase, async: false

  @moduletag :polls
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.Polls.Confirm
  alias Tymeslot.TestMocks

  setup do
    TestMocks.resolve_booking_calendars()

    user = insert(:user)
    insert(:profile, user: user)
    poll = insert(:poll, user: user, status: :open, timezone: "Etc/UTC", meeting_type_id: nil)

    start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

    slot =
      insert(:poll_time_slot,
        poll: poll,
        start_time: start_time,
        end_time: DateTime.add(start_time, 1, :hour)
      )

    named = insert(:poll_participant, poll: poll, name: "Ben Ito", email: "ben@example.com")
    insert(:poll_vote, participant: named, time_slot: slot, response: :yes)

    # Invited by address and never voted, so they never gave a name.
    insert(:poll_participant, poll: poll, name: nil, email: "nameless@example.com")

    %{user: user, poll: poll, slot: slot}
  end

  test "stores each participant's name on their guest row", %{user: user, poll: poll, slot: slot} do
    assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)

    names = meeting.id |> Guests.list_for_meeting() |> Map.new(&{&1.email, &1.name})

    assert names == %{"ben@example.com" => "Ben Ito", "nameless@example.com" => nil}
  end

  describe "the confirmation emails" do
    setup do
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
      Application.put_env(:swoosh, :shared_test_process, self())

      on_exit(fn ->
        Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
        Application.delete_env(:swoosh, :shared_test_process)
      end)
    end

    test "address a guest by the name they gave", %{user: user, poll: poll, slot: slot} do
      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)

      EmailHandlers.execute_email_action("send_confirmation_emails", %{
        "meeting_id" => meeting.id
      })

      assert_received {:email, %Swoosh.Email{to: [{"Ben Ito", "ben@example.com"}]} = email}
      assert email.text_body =~ "Hi Ben Ito"
      refute email.text_body =~ "Hi ben@example.com"
    end

    test "name the guests in the host's email", %{user: user, poll: poll, slot: slot} do
      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)

      EmailHandlers.execute_email_action("send_confirmation_emails", %{
        "meeting_id" => meeting.id
      })

      host_email = user.email
      assert_received {:email, %Swoosh.Email{to: [{_name, ^host_email}]} = email}
      assert email.text_body =~ "Ben Ito"
      assert email.html_body =~ "Ben Ito"
      assert email.text_body =~ "nameless@example.com"
    end
  end
end
