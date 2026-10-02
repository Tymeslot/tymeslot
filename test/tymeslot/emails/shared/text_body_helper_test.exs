defmodule Tymeslot.Emails.Shared.TextBodyHelperTest do
  use ExUnit.Case, async: true

  @moduletag :emails

  alias Tymeslot.Emails.Shared.TextBodyHelper

  defp details(overrides) do
    Map.merge(
      %{
        date: ~D[2026-01-15],
        start_time: ~U[2026-01-15 14:00:00Z],
        duration: 60,
        location: "In person",
        location_type: :in_person_to_arrange,
        meeting_type: "Consultation"
      },
      overrides
    )
  end

  describe "format_meeting_details/2" do
    test "puts the arranged-after-booking note on the line after the location" do
      text = TextBodyHelper.format_meeting_details(details(%{}), "en")

      assert text =~
               "Location: In person\nThe address will be arranged with you after booking."
    end

    test "adds no note for a meeting with an address" do
      text =
        TextBodyHelper.format_meeting_details(
          details(%{location: "Berlin office (Friedrichstrasse 1)", location_type: :in_person}),
          "en"
        )

      assert text =~ "Location: Berlin office (Friedrichstrasse 1)"
      refute text =~ "arranged with you after booking"
    end

    test "writes the note in the recipient's language" do
      text = TextBodyHelper.format_meeting_details(details(%{}), "de")

      assert text =~ "Die Adresse wird nach der Buchung mit Ihnen abgestimmt."
    end
  end
end
