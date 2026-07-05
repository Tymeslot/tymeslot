defmodule Tymeslot.Bookings.OrchestratorIdorTest do
  @moduledoc """
  Regression tests for IDOR vulnerabilities in the booking orchestrator.

  Covers two attack surfaces:

  1. `get_meeting_for_reschedule/2` — an attacker who knows a victim's meeting
     UID must not be able to read the victim's attendee PII (name, email, message)
     by passing that UID as `reschedule_meeting_uid` on their own scheduling page.

  2. `submit_booking/2` with `organizer_user_id` opt — an attacker must not be
     able to reschedule a victim's meeting by injecting the victim's meeting UID
     into the `reschedule_uid` opt while providing their own `organizer_user_id`.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :bookings
  @moduletag :security

  import Mox
  import Tymeslot.Factory
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Issue 2 — attendee PII pre-fill leak
  # ---------------------------------------------------------------------------

  describe "get_meeting_for_reschedule/2 — organizer scoping" do
    test "returns meeting data when organizer_user_id matches the meeting owner" do
      %{user: owner} = create_user_with_profile()
      meeting = insert_meeting_for_user(owner)

      assert {:ok, fetched} = Orchestrator.get_meeting_for_reschedule(meeting.uid, owner.id)
      assert fetched.id == meeting.id
    end

    test "returns not-found error when organizer_user_id belongs to a different user" do
      %{user: victim} = create_user_with_profile()
      victim_meeting = insert_meeting_for_user(victim)

      attacker = insert(:user)
      insert(:profile, user: attacker)

      # Attacker passes victim's UID but their own user ID — must be rejected
      assert {:error, :meeting_not_found} =
               Orchestrator.get_meeting_for_reschedule(victim_meeting.uid, attacker.id)
    end

    test "returns not-found error for a completely unknown UID regardless of organizer" do
      attacker = insert(:user)
      insert(:profile, user: attacker)

      assert {:error, :meeting_not_found} =
               Orchestrator.get_meeting_for_reschedule("totally-fake-uid", attacker.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Issue 1 — booking-form-submission IDOR write path
  # ---------------------------------------------------------------------------

  describe "submit_booking/2 with organizer_user_id opt — ownership enforcement" do
    test "rejects rescheduling when organizer_user_id does not own the target meeting" do
      %{user: victim} = create_user_with_profile()
      victim_meeting = insert_meeting_for_user(victim)

      attacker = insert(:user)
      insert(:profile, user: attacker)

      params = %{
        form_data: %{"name" => "Attacker", "email" => "attacker@evil.com"},
        meeting_params: %{
          date: Date.to_string(Date.add(Date.utc_today(), 3)),
          time: "10:00 AM",
          duration: "30min",
          user_timezone: "UTC",
          organizer_user_id: attacker.id
        }
      }

      opts = [
        is_rescheduling: true,
        reschedule_uid: victim_meeting.uid,
        organizer_user_id: attacker.id
      ]

      # The orchestrator must reject the cross-organizer attempt
      assert {:error, _reason} = Orchestrator.submit_booking(params, opts)
    end

    test "returns a clean error when organizer_user_id is nil (profile resolution failed)" do
      %{user: owner} = create_user_with_profile()
      owner_meeting = insert_meeting_for_user(owner)

      params = %{
        form_data: %{"name" => "Visitor", "email" => "visitor@example.com"},
        meeting_params: %{
          date: Date.to_string(Date.add(Date.utc_today(), 3)),
          time: "10:00 AM",
          duration: "30min",
          user_timezone: "UTC"
        }
      }

      opts = [
        is_rescheduling: true,
        reschedule_uid: owner_meeting.uid,
        organizer_user_id: nil
      ]

      # A nil organizer_user_id reaching the reschedule path must return an
      # error tuple, not raise FunctionClauseError. The domain layer
      # surfaces the semantic :meeting_not_found atom — the web layer, not
      # the domain layer, renders it to display text.
      assert {:error, :meeting_not_found} = Orchestrator.submit_booking(params, opts)
    end

    test "allows rescheduling when organizer_user_id matches the meeting owner" do
      %{user: owner} = create_user_with_profile()
      owner_meeting = insert_meeting_for_user(owner)

      params = %{
        form_data: %{"name" => "Owner", "email" => "owner@example.com"},
        meeting_params: %{
          date: Date.to_string(Date.add(Date.utc_today(), 3)),
          time: "10:00 AM",
          duration: "30min",
          user_timezone: "UTC",
          organizer_user_id: owner.id
        }
      }

      opts = [
        is_rescheduling: true,
        reschedule_uid: owner_meeting.uid,
        organizer_user_id: owner.id
      ]

      assert {:ok, updated} = Orchestrator.submit_booking(params, opts)
      assert updated.id == owner_meeting.id
    end
  end
end
