defmodule Tymeslot.Meetings.OrganiserOwnershipTest do
  @moduledoc """
  Who a booking belongs to on the organiser's dashboard.

  A booking belongs to the account that organises it, recorded as
  `organizer_user_id`. The `organizer_email` and `attendee_email` columns are
  snapshots of addresses taken when the booking was made, kept for the emails;
  an address can change hands, so neither may decide whose dashboard a booking
  appears on or who may cancel it.

  The scenario these tests replay: a host changes their account address, and
  somebody else later signs up under the address the host gave up. The host
  must keep their bookings; the newcomer must see none of them and be unable
  to cancel them. A user who was merely booked as somebody else's attendee is
  not that meeting's organiser either.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :meetings
  @moduletag :integration

  import Mox
  import Tymeslot.MeetingTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Agenda
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()

    old_email = "host-#{System.unique_integer([:positive])}@example.com"
    host = user_with_profile(old_email)

    meeting =
      insert_meeting_for_user(host, %{
        title: "Host's client call",
        attendee_name: "Confidential Attendee",
        attendee_email: "client-#{System.unique_integer([:positive])}@example.com",
        start_offset: 86_400
      })

    host = change_email(host, "host-renamed-#{System.unique_integer([:positive])}@example.com")

    # The address the host gave up, verified by someone else.
    claimant = user_with_profile(old_email)

    {:ok, host: host, claimant: claimant, meeting: meeting, old_email: old_email}
  end

  defp user_with_profile(email) do
    user = insert(:user, email: email)
    insert(:profile, user: user)
    user
  end

  defp change_email(user, email),
    do: user |> Changeset.change(email: email) |> Repo.update!()

  defp upcoming_ids(user) do
    {:ok, page} = Meetings.list_user_meetings_by_filter(user.id, "upcoming")
    Enum.map(page.items, & &1.id)
  end

  defp agenda_titles(user) do
    day = Agenda.day_agenda(user, "Etc/UTC")

    [day.next | day.today ++ day.tomorrow]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.title)
  end

  describe "a host who changes their account address" do
    test "still sees their bookings in the list", %{host: host, meeting: meeting} do
      assert upcoming_ids(host) == [meeting.id]
    end

    test "still sees their bookings on the agenda", %{host: host} do
      assert agenda_titles(host) == ["Host's client call"]
    end

    test "can still open and cancel them", %{host: host, meeting: meeting} do
      assert {:ok, _meeting} = Meetings.get_meeting_for_organizer(meeting.id, host.id)
      assert {:ok, cancelled} = Meetings.cancel_meeting_with_refund(meeting, host.id, :none)
      assert cancelled.status == "cancelled"
    end
  end

  describe "whoever later verifies the host's old address" do
    test "sees none of the host's bookings in the list", %{claimant: claimant, meeting: meeting} do
      assert meeting.organizer_email == claimant.email,
             "the snapshot must still carry the old address, or this proves nothing"

      assert upcoming_ids(claimant) == []
    end

    test "sees none of them on the agenda", %{claimant: claimant} do
      assert agenda_titles(claimant) == []
    end

    test "cannot open one", %{claimant: claimant, meeting: meeting} do
      assert {:error, :not_found} = Meetings.get_meeting_for_organizer(meeting.id, claimant.id)
    end

    test "cannot cancel one", %{claimant: claimant, meeting: meeting} do
      assert {:error, :not_found} =
               Meetings.cancel_meeting_with_refund(meeting, claimant.id, :none)

      assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(meeting.id)
    end
  end

  describe "a user booked as the attendee of somebody else's meeting" do
    setup %{host: host} do
      %{user: attendee} = create_user_with_profile()

      booked_on =
        insert_meeting_for_user(host, %{
          title: "Booked as attendee",
          attendee_email: attendee.email,
          start_offset: 2 * 86_400
        })

      {:ok, attendee: attendee, booked_on: booked_on}
    end

    test "does not see it in their organiser list", %{attendee: attendee} do
      assert upcoming_ids(attendee) == []
    end

    test "does not see it on their agenda", %{attendee: attendee} do
      assert agenda_titles(attendee) == []
    end

    test "cannot cancel it from the organiser path", %{
      attendee: attendee,
      booked_on: booked_on
    } do
      assert {:error, :not_found} =
               Meetings.cancel_meeting_with_refund(booked_on, attendee.id, :none)

      assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(booked_on.id)
    end
  end

  describe "cancelling with no acting user" do
    test "is refused", %{meeting: meeting} do
      assert {:error, :not_found} = Meetings.cancel_meeting_with_refund(meeting, nil, :none)
      assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(meeting.id)
    end
  end
end
