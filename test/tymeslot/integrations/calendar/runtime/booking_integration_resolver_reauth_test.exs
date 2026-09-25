defmodule Tymeslot.Integrations.Calendar.Runtime.BookingIntegrationResolverReauthTest do
  @moduledoc """
  The booking-target tier `booking_integration_resolver_test.exs` does not
  cover: an integration the token refresh job has flagged for reconnection.

  The refresh job leaves an integration whose credentials the provider
  refused `is_active: true` and sets `needs_reauth` instead, so `is_active`
  alone no longer says whether a write to it can succeed. Resolving one
  fails the calendar event job on every booking and alerts the owner each
  time, while their other calendar sits unused. Kept as its own module so the
  main resolver suite stays under the module size limit.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Runtime.BookingIntegrationResolver
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  describe "an integration flagged for reconnection" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "a meeting type recording a flagged integration falls back to the user's other integration",
         %{user: user} do
      healthy =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/healthy/"],
          default_booking_calendar_id: "/calendars/healthy/"
        )

      flagged =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          is_active: true,
          needs_reauth: true,
          default_booking_calendar_id: "primary"
        )

      insert(:profile, user: user, primary_calendar_integration_id: healthy.id)

      meeting_type = %MeetingTypeSchema{
        user_id: user.id,
        calendar_integration_id: flagged.id,
        target_calendar_id: "primary"
      }

      result = BookingIntegrationResolver.resolve(meeting_type)

      assert %CalendarIntegrationSchema{} = result
      assert result.id == healthy.id
      # The fallback keeps its own booking calendar rather than inheriting the
      # flagged integration's target.
      assert result.default_booking_calendar_id == "/calendars/healthy/"
    end

    test "a meeting recording a flagged integration falls back to the organiser's other integration",
         %{user: user} do
      healthy =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/healthy/"],
          default_booking_calendar_id: "/calendars/healthy/"
        )

      flagged =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          is_active: true,
          needs_reauth: true,
          default_booking_calendar_id: "primary"
        )

      insert(:profile, user: user, primary_calendar_integration_id: healthy.id)

      meeting = %MeetingSchema{
        organizer_user_id: user.id,
        calendar_integration_id: flagged.id,
        calendar_path: "primary"
      }

      result = BookingIntegrationResolver.resolve(meeting)

      assert %CalendarIntegrationSchema{} = result
      assert result.id == healthy.id
    end

    test "a flagged primary is skipped for the user's other integration", %{user: user} do
      flagged =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          is_active: true,
          needs_reauth: true,
          default_booking_calendar_id: "primary"
        )

      healthy =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/healthy/"],
          default_booking_calendar_id: nil
        )

      insert(:profile, user: user, primary_calendar_integration_id: flagged.id)

      result = BookingIntegrationResolver.resolve(user.id)

      assert %CalendarIntegrationSchema{} = result
      assert result.id == healthy.id
    end

    test "resolves to nothing when the user's only integration is flagged", %{user: user} do
      flagged =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          is_active: true,
          needs_reauth: true,
          default_booking_calendar_id: "primary"
        )

      insert(:profile, user: user, primary_calendar_integration_id: flagged.id)

      assert BookingIntegrationResolver.resolve(user.id) == nil
      assert BookingIntegrationResolver.resolve({flagged.id, user.id}) == nil
    end

    test "a paused primary is skipped even though it has a booking calendar", %{user: user} do
      paused =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: false,
          calendar_paths: ["/calendars/paused/"],
          default_booking_calendar_id: "/calendars/paused/"
        )

      healthy =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/healthy/"],
          default_booking_calendar_id: "/calendars/healthy/"
        )

      insert(:profile, user: user, primary_calendar_integration_id: paused.id)

      result = BookingIntegrationResolver.resolve(user.id)

      assert %CalendarIntegrationSchema{} = result
      assert result.id == healthy.id
    end
  end
end
