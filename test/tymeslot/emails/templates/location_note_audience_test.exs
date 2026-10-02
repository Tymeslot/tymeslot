defmodule Tymeslot.Emails.Templates.LocationNoteAudienceTest do
  @moduledoc """
  The note under an in-person location whose address is arranged after
  booking, as each recipient of a booking's emails reads it: the booker is
  told it will be arranged with them, the host to arrange it with the
  booker, and a guest the booker invited only that it will be arranged. A
  cancellation carries no note at all: there is no address left to arrange.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.Templates.{
    AppointmentCancellation,
    AppointmentConfirmation,
    AppointmentReminder,
    AppointmentRescheduled
  }

  @booker_note "The address will be arranged with you after booking."
  @host_note "The address is to be arranged with the booker."
  @guest_note "The address will be arranged after booking."

  defp to_arrange do
    build_appointment_details(%{
      location: "In person",
      location_type: :in_person_to_arrange,
      guest_name: "Greg Guest"
    })
  end

  for template <- [AppointmentConfirmation, AppointmentReminder, AppointmentRescheduled] do
    describe "#{inspect(template)} to a guest" do
      test "says the address will be arranged, without promising it to them" do
        email = unquote(template).render(:guest, "greg@example.com", to_arrange())

        assert email.html_body =~ @guest_note
        assert email.text_body =~ @guest_note
        refute email.html_body =~ @booker_note
        refute email.text_body =~ @booker_note
      end
    end
  end

  describe "AppointmentCancellation" do
    for audience <- [:attendee, :organizer, :guest] do
      test "carries no arranged-address note to the #{audience}" do
        email =
          AppointmentCancellation.render(unquote(audience), "someone@example.com", to_arrange())

        for note <- [@booker_note, @host_note, @guest_note] do
          refute email.html_body =~ note
          refute email.text_body =~ note
        end

        assert email.text_body =~ "In person"
      end
    end
  end
end
