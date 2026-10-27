defmodule Tymeslot.Emails.Shared.TemplateHelperTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.TemplateHelper

  describe "compile_system_template/4" do
    test "uses default preview when preview is nil" do
      content = "<mj-text>Test content</mj-text>"

      html =
        TemplateHelper.compile_system_template(content, "Test Title", nil,
          intent: :confirmed,
          eyebrow: "Notice"
        )

      # Should use default preview text from system_layout
      assert html =~ "Important notification from Tymeslot"
    end

    test "uses provided preview when not nil" do
      content = "<mj-text>Test content</mj-text>"

      html =
        TemplateHelper.compile_system_template(content, "Test Title", "Custom preview text",
          intent: :confirmed,
          eyebrow: "Notice"
        )

      assert html =~ "Custom preview text"
    end

    test "sanitizes title" do
      content = "<mj-text>Test</mj-text>"

      html =
        TemplateHelper.compile_system_template(content, "<script>Title</script>", nil,
          intent: :confirmed,
          eyebrow: "Notice"
        )

      refute html =~ "<script>Title</script>"
      assert html =~ "&lt;script&gt;"
    end

    test "compiles valid HTML output" do
      content = "<mj-text>Hello World</mj-text>"

      html =
        TemplateHelper.compile_system_template(content, "Test", "Preview",
          intent: :confirmed,
          eyebrow: "Notice"
        )

      assert html =~ "<!doctype html>"
      assert html =~ "Hello World"
    end

    test "includes eyebrow and title in output" do
      content = "<mj-text>Body</mj-text>"

      html =
        TemplateHelper.compile_system_template(content, "My Title", nil,
          intent: :confirmed,
          eyebrow: "Confirmed"
        )

      assert html =~ "Confirmed"
      assert html =~ "My Title"
    end

    test "raises ArgumentError when :intent is missing from stage" do
      content = "<mj-text>Body</mj-text>"

      assert_raise ArgumentError, ~r/:intent/, fn ->
        TemplateHelper.compile_system_template(content, "Test", nil, eyebrow: "Notice")
      end
    end

    test "raises ArgumentError when :eyebrow is missing from stage" do
      content = "<mj-text>Body</mj-text>"

      assert_raise ArgumentError, ~r/:eyebrow/, fn ->
        TemplateHelper.compile_system_template(content, "Test", nil, intent: :confirmed)
      end
    end
  end

  describe "build_organizer_details/2" do
    test "builds a map with organiser name, email, and stage keys" do
      appointment_details = %{
        organizer_name: "Ada Lovelace",
        organizer_email: "ada@example.com",
        organizer_title: "Engineer",
        organizer_avatar_url: nil
      }

      result =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: :confirmed,
          eyebrow: "Confirmed"
        )

      assert result.name == "Ada Lovelace"
      assert result.email == "ada@example.com"
      assert result.intent == :confirmed
      assert result.eyebrow == "Confirmed"
    end

    test "raises ArgumentError when :intent is missing" do
      appointment_details = %{
        organizer_name: "Ada",
        organizer_email: "ada@example.com",
        organizer_title: nil,
        organizer_avatar_url: nil
      }

      assert_raise ArgumentError, ~r/:intent/, fn ->
        TemplateHelper.build_organizer_details(appointment_details, eyebrow: "Notice")
      end
    end

    test "raises ArgumentError when :eyebrow is missing" do
      appointment_details = %{
        organizer_name: "Ada",
        organizer_email: "ada@example.com",
        organizer_title: nil,
        organizer_avatar_url: nil
      }

      assert_raise ArgumentError, ~r/:eyebrow/, fn ->
        TemplateHelper.build_organizer_details(appointment_details, intent: :confirmed)
      end
    end
  end

  describe "meeting-details builders" do
    # 09:00 UTC: 10:00 in Berlin, 14:30 in Kolkata.
    defp payload(overrides \\ %{}) do
      start = ~U[2026-01-15 09:00:00Z]

      Map.merge(
        %{
          date: ~D[2026-01-15],
          duration: 60,
          location: "Somewhere",
          location_type: :in_person_to_arrange,
          meeting_type: "Consultation",
          start_time_owner_tz: DateTime.shift_zone!(start, "Europe/Berlin"),
          start_time_attendee_tz: DateTime.shift_zone!(start, "Asia/Kolkata"),
          attendee_timezone: "Asia/Kolkata",
          organizer_time_format: "24h"
        },
        overrides
      )
    end

    test "attendee_meeting_details/2 gives the booker their own time and zone" do
      details = TemplateHelper.attendee_meeting_details(payload(), :attendee)

      assert details.start_time == DateTime.shift_zone!(~U[2026-01-15 09:00:00Z], "Asia/Kolkata")
      assert details.start_time.time_zone == "Asia/Kolkata"
      refute Map.has_key?(details, :audience)
      refute Map.has_key?(details, :time_format)
    end

    test "attendee_meeting_details/2 marks a guest's map for the guest wording" do
      details = TemplateHelper.attendee_meeting_details(payload(), :guest)

      assert details.audience == :guest
      assert details.start_time.time_zone == "Asia/Kolkata"
    end

    test "attendee_meeting_details/2 carries an all-day event's days" do
      details =
        TemplateHelper.attendee_meeting_details(
          payload(%{all_day: true, last_date: ~D[2026-01-17]}),
          :attendee
        )

      assert details.all_day
      assert details.last_date == ~D[2026-01-17]
    end

    test "organizer_meeting_details/1 gives the organiser their own time, zone and clock" do
      details = TemplateHelper.organizer_meeting_details(payload())

      assert details.start_time ==
               DateTime.shift_zone!(~U[2026-01-15 09:00:00Z], "Europe/Berlin")

      assert details.time_format == "24h"
      assert details.audience == :host
    end
  end
end
