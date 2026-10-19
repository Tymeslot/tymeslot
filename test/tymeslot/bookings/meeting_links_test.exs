defmodule Tymeslot.Bookings.MeetingLinksTest do
  @moduledoc """
  A booking's cancel and reschedule links follow the host's current username,
  not the one stored on the row at booking time.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :bookings
  @moduletag :emails

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.Templates.AppointmentReminder
  alias Tymeslot.Emails.Templates.RescheduleRequest
  alias Tymeslot.Profiles
  alias Tymeslot.Webhooks.PayloadBuilder
  alias TymeslotWeb.Endpoint

  @base Endpoint.url()

  # A booking as it was stored when the host was called `booked_as`.
  defp booking(user, booked_as) do
    uid = UUID.generate()

    insert(
      :meeting,
      Map.merge(%{uid: uid, organizer_user_id: user.id}, MeetingLinks.build(booked_as, uid))
    )
  end

  defp rename!(profile, username) do
    {:ok, profile} = Profiles.change_username(profile, username)
    profile
  end

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "links-before")
    %{user: user, profile: profile}
  end

  describe "after the host changes username" do
    setup %{user: user, profile: profile} do
      meeting = booking(user, "links-before")
      rename!(profile, "links-after")
      %{meeting: meeting}
    end

    test "for_meeting/1 builds the links with the new username", %{meeting: meeting} do
      assert MeetingLinks.for_meeting(meeting) == %{
               view_url: "#{@base}/dashboard/meetings?meeting=#{meeting.id}",
               reschedule_url: "#{@base}/links-after/meeting/#{meeting.uid}/reschedule",
               cancel_url: "#{@base}/links-after/meeting/#{meeting.uid}/cancel"
             }
    end

    test "for_meeting/2 builds them from the profile it is handed", %{meeting: meeting} do
      {:ok, profile} = Profiles.get_profile_by_user_id(meeting.organizer_user_id)

      assert MeetingLinks.for_meeting(meeting, profile) == MeetingLinks.for_meeting(meeting)

      assert MeetingLinks.for_meeting(meeting, nil).cancel_url ==
               "#{@base}/meeting/#{meeting.uid}/cancel"
    end

    test "a reminder carries the new username's links", %{meeting: meeting} do
      details = AppointmentBuilder.from_meeting(meeting, %{value: 30, unit: "minutes"})
      email = AppointmentReminder.render(:attendee, meeting.attendee_email, details)

      assert email.html_body =~ "#{@base}/links-after/meeting/#{meeting.uid}/cancel"
      assert email.html_body =~ "#{@base}/links-after/meeting/#{meeting.uid}/reschedule"
      refute email.html_body =~ "/links-before/"
      refute email.text_body =~ "/links-before/"
    end

    test "a reschedule request carries the new username's link", %{meeting: meeting} do
      email = RescheduleRequest.render(meeting)

      assert email.html_body =~ "#{@base}/links-after/meeting/#{meeting.uid}/reschedule"
      assert email.text_body =~ "#{@base}/links-after/meeting/#{meeting.uid}/reschedule"
      refute email.html_body =~ "/links-before/"
    end

    test "the webhook payload keeps its url keys and carries the new links", %{meeting: meeting} do
      urls = PayloadBuilder.build_payload("meeting.created", meeting, "1").data.meeting.urls

      assert Enum.sort(Map.keys(urls)) == [:cancel, :meeting, :reschedule, :view]
      assert urls.cancel == "#{@base}/links-after/meeting/#{meeting.uid}/cancel"
      assert urls.reschedule == "#{@base}/links-after/meeting/#{meeting.uid}/reschedule"
      assert urls.view == "#{@base}/dashboard/meetings?meeting=#{meeting.id}"
    end

    test "current_path/2 resolves the uid to the new username's page", %{meeting: meeting} do
      assert MeetingLinks.current_path(meeting.uid, :cancel) ==
               {:ok, "/links-after/meeting/#{meeting.uid}/cancel"}

      assert MeetingLinks.current_path(meeting.uid, :reschedule) ==
               {:ok, "/links-after/meeting/#{meeting.uid}/reschedule"}
    end
  end

  describe "a booking made before the host had a username" do
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user, username: nil)
      %{user: user, profile: profile, meeting: booking(user, nil)}
    end

    test "gets the username links once the host has one", %{profile: profile, meeting: meeting} do
      rename!(profile, "links-late")

      details = AppointmentBuilder.from_meeting(meeting, %{value: 30, unit: "minutes"})

      assert details.cancel_url == "#{@base}/links-late/meeting/#{meeting.uid}/cancel"
      assert details.reschedule_url == "#{@base}/links-late/meeting/#{meeting.uid}/reschedule"
    end

    test "gets the uid-only links while the host has none", %{meeting: meeting} do
      assert %{cancel_url: cancel_url} = MeetingLinks.for_meeting(meeting)
      assert cancel_url == "#{@base}/meeting/#{meeting.uid}/cancel"
      assert MeetingLinks.current_path(meeting.uid, :cancel) == {:error, :not_found}
    end
  end

  test "current_path/2 is not_found for an unknown uid" do
    assert MeetingLinks.current_path(UUID.generate(), :cancel) == {:error, :not_found}
  end
end
