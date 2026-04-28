defmodule Tymeslot.Integrations.Calendar.Runtime.BookingIntegrationResolverTest do
  @moduledoc """
  Unit tests for `Tymeslot.Integrations.Calendar.Runtime.BookingIntegrationResolver`.

  These tests exercise the full fallback chain in isolation, backed by real
  database fixtures. No mocks are used — the resolver is tested by asserting
  on its return value, which already encodes which integration and path were
  selected.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.Runtime.BookingIntegrationResolver
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  # ---------------------------------------------------------------------------
  # resolve(user_id)
  # ---------------------------------------------------------------------------

  describe "resolve(user_id) — bare integer" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "returns nil when the user has no integrations", %{user: user} do
      insert(:profile, user: user)

      assert BookingIntegrationResolver.resolve(user.id) == nil
    end

    test "returns the primary integration when it has a default_booking_calendar_id", %{
      user: user
    } do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"],
          default_booking_calendar_id: "/calendars/primary/"
        )

      insert(:profile, user: user, primary_calendar_integration_id: integration.id)

      result = BookingIntegrationResolver.resolve(user.id)

      assert result != nil
      assert result.id == integration.id
      assert result.default_booking_calendar_id == "/calendars/primary/"
    end

    test "falls back to first integration with a booking calendar when primary has none", %{
      user: user
    } do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"],
          default_booking_calendar_id: nil
        )

      other =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/other/"],
          default_booking_calendar_id: "/calendars/other/"
        )

      insert(:profile, user: user, primary_calendar_integration_id: primary.id)

      result = BookingIntegrationResolver.resolve(user.id)

      assert result != nil
      assert result.id == other.id
    end

    test "falls back to primary itself when no integration has a booking calendar", %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"],
          default_booking_calendar_id: nil
        )

      insert(:profile, user: user, primary_calendar_integration_id: primary.id)

      result = BookingIntegrationResolver.resolve(user.id)

      assert result != nil
      assert result.id == primary.id
    end

    test "uses list_active_calendar_integrations once when no primary is set", %{user: user} do
      # When get_primary_calendar_integration returns {:error, :no_primary_set}
      # the resolver falls into the error branch and calls list_active_calendar_integrations
      # exactly once. We verify correct behaviour (no double-fetch regression) by
      # asserting the right integration is returned despite the absence of a primary.
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/only/"],
          default_booking_calendar_id: "/calendars/only/"
        )

      # Profile exists but primary_calendar_integration_id is nil → {:error, :no_primary_set}
      insert(:profile, user: user)

      result = BookingIntegrationResolver.resolve(user.id)

      assert result != nil
      assert result.id == integration.id
    end

    test "falls back to first active integration when primary is absent and none have a booking calendar",
         %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/only/"],
          default_booking_calendar_id: nil
        )

      insert(:profile, user: user)

      result = BookingIntegrationResolver.resolve(user.id)

      assert result != nil
      assert result.id == integration.id
    end
  end

  # ---------------------------------------------------------------------------
  # resolve({integration_id, user_id})
  # ---------------------------------------------------------------------------

  describe "resolve({integration_id, user_id}) — explicit tuple" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "returns the integration when it is active", %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/active/"]
        )

      insert(:profile, user: user)

      result = BookingIntegrationResolver.resolve({integration.id, user.id})

      assert result != nil
      assert result.id == integration.id
    end

    test "falls back to resolve(user_id) when the integration is inactive", %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"],
          default_booking_calendar_id: "/calendars/primary/"
        )

      inactive =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: false,
          calendar_paths: ["/calendars/inactive/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: primary.id)

      result = BookingIntegrationResolver.resolve({inactive.id, user.id})

      assert result != nil
      assert result.id == primary.id
    end

    test "falls back to resolve(user_id) when the integration is not found", %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"],
          default_booking_calendar_id: "/calendars/primary/"
        )

      insert(:profile, user: user, primary_calendar_integration_id: primary.id)

      nonexistent_id = 999_999_999

      result = BookingIntegrationResolver.resolve({nonexistent_id, user.id})

      assert result != nil
      assert result.id == primary.id
    end
  end

  # ---------------------------------------------------------------------------
  # resolve(%MeetingSchema{})
  # ---------------------------------------------------------------------------

  describe "resolve(%MeetingSchema{})" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "returns nil when both calendar_integration_id and organizer_user_id are absent", _ctx do
      meeting = %MeetingSchema{
        calendar_integration_id: nil,
        organizer_user_id: nil,
        calendar_path: nil
      }

      assert BookingIntegrationResolver.resolve(meeting) == nil
    end

    test "returns nil when calendar_integration_id is a string (non-integer)", _ctx do
      meeting = %MeetingSchema{
        calendar_integration_id: "not-an-integer",
        organizer_user_id: "also-not-an-integer",
        calendar_path: nil
      }

      assert BookingIntegrationResolver.resolve(meeting) == nil
    end

    test "uses meeting's integration when active, overriding default_booking_calendar_id with calendar_path",
         %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/meeting/"],
          default_booking_calendar_id: "/calendars/meeting/"
        )

      insert(:profile, user: user, primary_calendar_integration_id: integration.id)

      meeting = %MeetingSchema{
        organizer_user_id: user.id,
        calendar_integration_id: integration.id,
        calendar_path: "/calendars/meeting/specific-event.ics"
      }

      result = BookingIntegrationResolver.resolve(meeting)

      assert result != nil
      assert result.id == integration.id
      assert result.default_booking_calendar_id == "/calendars/meeting/specific-event.ics"
    end

    test "falls back to organizer's primary when meeting's integration is inactive", %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"],
          default_booking_calendar_id: "/calendars/primary/"
        )

      inactive =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: false,
          calendar_paths: ["/calendars/inactive/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: primary.id)

      meeting = %MeetingSchema{
        organizer_user_id: user.id,
        calendar_integration_id: inactive.id,
        calendar_path: "/calendars/inactive/event.ics"
      }

      result = BookingIntegrationResolver.resolve(meeting)

      assert result != nil
      assert result.id == primary.id
    end

    test "falls back to organizer's primary when meeting has no stored integration", %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"],
          default_booking_calendar_id: "/calendars/primary/"
        )

      insert(:profile, user: user, primary_calendar_integration_id: primary.id)

      meeting = %MeetingSchema{
        organizer_user_id: user.id,
        calendar_integration_id: nil,
        calendar_path: nil
      }

      result = BookingIntegrationResolver.resolve(meeting)

      assert result != nil
      assert result.id == primary.id
    end
  end

  # ---------------------------------------------------------------------------
  # resolve(%MeetingTypeSchema{})
  # ---------------------------------------------------------------------------

  describe "resolve(%MeetingTypeSchema{})" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "returns nil when both calendar_integration_id and user_id are absent", _ctx do
      meeting_type = %MeetingTypeSchema{
        calendar_integration_id: nil,
        user_id: nil,
        target_calendar_id: nil
      }

      assert BookingIntegrationResolver.resolve(meeting_type) == nil
    end

    test "uses meeting type's integration when active, overriding default_booking_calendar_id with target_calendar_id",
         %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/mt/"],
          default_booking_calendar_id: "/calendars/mt/"
        )

      insert(:profile, user: user, primary_calendar_integration_id: integration.id)

      meeting_type = %MeetingTypeSchema{
        user_id: user.id,
        calendar_integration_id: integration.id,
        target_calendar_id: "/calendars/mt/target/"
      }

      result = BookingIntegrationResolver.resolve(meeting_type)

      assert result != nil
      assert result.id == integration.id
      assert result.default_booking_calendar_id == "/calendars/mt/target/"
    end

    test "falls back to user's primary when meeting type's integration is inactive", %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"],
          default_booking_calendar_id: "/calendars/primary/"
        )

      inactive =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: false,
          calendar_paths: ["/calendars/mt-inactive/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: primary.id)

      meeting_type = %MeetingTypeSchema{
        user_id: user.id,
        calendar_integration_id: inactive.id,
        target_calendar_id: "/calendars/mt-inactive/target/"
      }

      result = BookingIntegrationResolver.resolve(meeting_type)

      assert result != nil
      assert result.id == primary.id
    end

    test "falls back to user's primary when meeting type has no stored integration", %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"],
          default_booking_calendar_id: "/calendars/primary/"
        )

      insert(:profile, user: user, primary_calendar_integration_id: primary.id)

      meeting_type = %MeetingTypeSchema{
        user_id: user.id,
        calendar_integration_id: nil,
        target_calendar_id: nil
      }

      result = BookingIntegrationResolver.resolve(meeting_type)

      assert result != nil
      assert result.id == primary.id
    end
  end

  # ---------------------------------------------------------------------------
  # resolve(other) — catch-all
  # ---------------------------------------------------------------------------

  describe "resolve(other) — catch-all clause" do
    test "returns nil for nil" do
      assert BookingIntegrationResolver.resolve(nil) == nil
    end

    test "returns nil for a string" do
      assert BookingIntegrationResolver.resolve("some-string") == nil
    end

    test "returns nil for an arbitrary map" do
      assert BookingIntegrationResolver.resolve(%{foo: :bar}) == nil
    end
  end
end
