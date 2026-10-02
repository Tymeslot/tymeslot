defmodule Tymeslot.Bookings.BookingTitleTest do
  use ExUnit.Case, async: true

  @moduletag :bookings
  @moduletag :i18n

  alias Tymeslot.Bookings.BookingTitle

  defp booking(title),
    do: %{title: title, meeting_type: "IRIS Demo", attendee_name: "Jane Doe"}

  describe "localise/2" do
    test "renders a title built in the organiser's language in the reader's" do
      assert BookingTitle.localise(booking("IRIS Demo mit Jane Doe"), "fr") ==
               "IRIS Demo avec Jane Doe"
    end

    # Bookings made before the title was translated hold the English one.
    test "renders an English title from before translation in the reader's language" do
      assert BookingTitle.localise(booking("IRIS Demo with Jane Doe"), "de") ==
               "IRIS Demo mit Jane Doe"
    end

    test "renders the title in English for an English reader" do
      assert BookingTitle.localise(booking("IRIS Demo mit Jane Doe"), "en") ==
               "IRIS Demo with Jane Doe"
    end

    test "leaves a title the template did not build as it is" do
      assert BookingTitle.localise(booking("Quarterly review"), "de") == "Quarterly review"
    end

    # The template matched, but for a different attendee name: the title was
    # built for someone else, or the name was edited since, so it is not
    # rebuilt from the current name.
    test "leaves a title naming someone other than the attendee as it is" do
      assert BookingTitle.localise(booking("IRIS Demo with John Roe"), "de") ==
               "IRIS Demo with John Roe"
    end

    test "returns the stored title when the meeting type is missing" do
      meeting = %{title: "IRIS Demo with Jane Doe", meeting_type: nil, attendee_name: "Jane Doe"}

      assert BookingTitle.localise(meeting, "de") == "IRIS Demo with Jane Doe"
    end

    test "returns nil for a meeting without a title" do
      assert BookingTitle.localise(booking(nil), "de") == nil
    end
  end
end
