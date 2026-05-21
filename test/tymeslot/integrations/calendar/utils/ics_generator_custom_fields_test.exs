defmodule Tymeslot.Integrations.Calendar.IcsGeneratorCustomFieldsTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.IcsGenerator

  describe "custom field answers in description" do
    test "appends label:value lines for each custom field answer" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "custom-fields-123",
        organizer_email: "host@example.com",
        custom_fields_snapshot: [
          %{"id" => "f1", "type" => "short_text", "label" => "Company"},
          %{"id" => "f2", "type" => "yes_no", "label" => "Bringing laptop"}
        ],
        custom_field_answers: %{"f1" => "Acme", "f2" => true}
      }

      ics = IcsGenerator.generate_ics(meeting_details)

      assert ics =~ "Company: Acme"
      assert ics =~ "Bringing laptop: Yes"
    end

    test "skips the answers block when custom_fields_snapshot is absent" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "no-custom-fields-123",
        organizer_email: "host@example.com"
      }

      ics = IcsGenerator.generate_ics(meeting_details)

      refute ics =~ "Company:"
    end

    test "skips the answers block when custom_fields_snapshot is an empty list" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "empty-snap-123",
        organizer_email: "host@example.com",
        custom_fields_snapshot: [],
        custom_field_answers: %{}
      }

      ics = IcsGenerator.generate_ics(meeting_details)

      refute ics =~ ": "
    end

    test "renders multi-select answers as comma-separated labels" do
      meeting_details = %{
        title: "Meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "multi-select-123",
        organizer_email: "host@example.com",
        custom_fields_snapshot: [
          %{
            "id" => "f1",
            "type" => "multi_select",
            "label" => "Topics",
            "options" => [
              %{"key" => "a", "label" => "Design"},
              %{"key" => "b", "label" => "Engineering"}
            ]
          }
        ],
        custom_field_answers: %{"f1" => ["a", "b"]}
      }

      ics = IcsGenerator.generate_ics(meeting_details)

      # Commas are escaped to \, in ICS
      assert ics =~ "Topics: Design\\, Engineering"
    end

    test "answers block is separated from preceding description by a double newline" do
      meeting_details = %{
        title: "Meeting",
        description: "An important meeting",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "separator-123",
        organizer_email: "host@example.com",
        custom_fields_snapshot: [
          %{"id" => "f1", "type" => "short_text", "label" => "Company"}
        ],
        custom_field_answers: %{"f1" => "Acme"}
      }

      ics = IcsGenerator.generate_ics(meeting_details)

      # In ICS the description is escaped, so real "\n\n" becomes "\\n\\n"
      assert ics =~ "An important meeting\\n\\nCompany: Acme"
    end
  end
end
