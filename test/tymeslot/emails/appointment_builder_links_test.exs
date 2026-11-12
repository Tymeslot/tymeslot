defmodule Tymeslot.Emails.AppointmentBuilderLinksTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.AppointmentBuilder
  alias TymeslotWeb.Endpoint

  import Tymeslot.MeetingTestHelpers

  describe "from_meeting/1 host links and booking page URL" do
    test "derives the host's booking page URL from their username" do
      %{user: user} = create_user_with_profile(%{username: "sarah-rodriguez"})
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.booking_url == "http://localhost:4002/sarah-rodriguez"
    end

    test "carries the host's uploaded avatar as an absolute URL" do
      %{user: user, profile: profile} = create_user_with_profile(%{avatar: "photo.png"})
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.organizer_avatar_url ==
               "http://localhost:4002/uploads/avatars/#{profile.id}/photo.png"
    end

    test "leaves the avatar unset, never a data URI, when the host has not uploaded one" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.organizer_avatar_url == nil
    end

    test "falls back to the app root when the host has no username" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.booking_url == "http://localhost:4002"
    end

    test "includes all URL fields with fallback to '#'" do
      %{user: user} = create_user_with_profile()

      # A group meeting has no public uid links of its own; its participants'
      # seat links are laid over it per recipient.
      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          capacity: 3,
          view_url: nil,
          reschedule_url: nil,
          cancel_url: nil
        })

      result = AppointmentBuilder.from_meeting(meeting)

      # No link stands in for a missing one; the view link is the host's
      # dashboard view, which a group meeting has like any other.
      assert result.view_url == "#{Endpoint.url()}/dashboard/meetings?meeting=#{meeting.id}"
      assert result.reschedule_url == nil
      assert result.cancel_url == nil
    end

    test "builds the links from the host's current username, ignoring the stored copy" do
      %{user: user} = create_user_with_profile(%{username: "builder-host"})

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          view_url: "https://app.example.com/meetings/123",
          reschedule_url: "https://app.example.com/reschedule/token123",
          cancel_url: "https://app.example.com/cancel/token123"
        })

      result = AppointmentBuilder.from_meeting(meeting)
      base = Endpoint.url() <> "/builder-host/meeting/#{meeting.uid}"

      assert result.view_url == "#{Endpoint.url()}/dashboard/meetings?meeting=#{meeting.id}"
      assert result.reschedule_url == base <> "/reschedule"
      assert result.cancel_url == base <> "/cancel"
    end

    test "reads the host's username once for the links and the booking page URL" do
      %{user: user} = create_user_with_profile(%{username: "builder-once"})
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      parent = self()
      ref = make_ref()
      handler_id = "appointment-builder-query-spy-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        # The handler runs in the process that issued the query, so this is
        # what keeps a concurrently running async test's queries out.
        fn _event, _measurements, %{source: source, query: query}, _config ->
          if self() == parent, do: send(parent, {:query, ref, source, query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.cancel_url =~ "/builder-once/meeting/#{meeting.uid}/cancel"
      assert result.booking_url =~ "/builder-once"

      # One read for the host's timezone, one for the profile the avatar, the
      # booking page URL and the action links are all built from. The links
      # used to read the profile a third time.
      assert length(drain_profile_reads(ref, [])) == 2
    end
  end

  defp drain_profile_reads(ref, acc) do
    receive do
      {:query, ^ref, "profiles", query} -> drain_profile_reads(ref, [query | acc])
      {:query, ^ref, _source, _query} -> drain_profile_reads(ref, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end
end
