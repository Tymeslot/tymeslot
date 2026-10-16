defmodule TymeslotWeb.Themes.Shared.ConfirmationTextTest do
  @moduledoc """
  What a confirmation screen announces is decided once for every theme: a
  booking held for approval must never read as confirmed, even when it is a
  reschedule, and the sentence that names the organiser must not borrow the
  "with %{name}" fragment, which is the wrong preposition for a request.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :themes
  @moduletag :unit

  import Tymeslot.Factory

  alias TymeslotWeb.Themes.Shared.ConfirmationText

  describe "status/1" do
    test "a held booking is :held, even when it is a reschedule" do
      assert ConfirmationText.status(%{
               meeting_status: "awaiting_approval",
               is_rescheduling: true
             }) ==
               :held
    end

    test "a reschedule that is not held is :rescheduled" do
      assert ConfirmationText.status(%{meeting_status: "confirmed", is_rescheduling: true}) ==
               :rescheduled
    end

    test "any other booking is :confirmed" do
      assert ConfirmationText.status(%{meeting_status: "confirmed"}) == :confirmed
    end
  end

  describe "held_message/3" do
    test "names the organiser the request went to" do
      organizer = build(:profile, full_name: "Jane Organizer")

      assert ConfirmationText.held_message("Alice", organizer) ==
               "Alice, your request to Jane Organizer has been sent."
    end

    test "leaves the organiser out when there is no name to give" do
      assert ConfirmationText.held_message("Alice", nil) == "Alice, your request has been sent."
    end

    test "is the theme's own sentence when its voice words it" do
      assert ConfirmationText.held_message("Alice", nil, :fixture) ==
               "Alice, your request is in."
    end

    test "keeps the shared sentence the voice does not word" do
      organizer = build(:profile, full_name: "Jane Organizer")

      assert ConfirmationText.held_message("Alice", organizer, :fixture) ==
               "Alice, your request to Jane Organizer has been sent."

      assert ConfirmationText.organizer_fragment(organizer, :fixture) == "with Jane Organizer"
    end
  end

  describe "organizer_fragment/1" do
    test "is the 'with' phrase for a named organiser" do
      organizer = build(:profile, full_name: "Jane Organizer")

      assert ConfirmationText.organizer_fragment(organizer) == "with Jane Organizer"
    end

    test "is empty without a profile" do
      assert ConfirmationText.organizer_fragment(nil) == ""
    end

    test "is translated" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")
      organizer = build(:profile, full_name: "Jane Organizer")

      assert ConfirmationText.organizer_fragment(organizer) == "mit Jane Organizer"
    end
  end
end
