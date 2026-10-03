defmodule TymeslotWeb.Dashboard.MeetingSettings.HelpersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers

  describe "format_errors/1" do
    test "formats list of errors" do
      assert Helpers.format_errors(["error 1", "error 2"]) == "error 1, error 2"
    end

    test "formats single string error" do
      assert Helpers.format_errors("single error") == "single error"
    end

    test "handles other types" do
      assert Helpers.format_errors(nil) == "An error occurred"
    end
  end

  describe "changeset_form_errors/1" do
    # The group rules are refused in the domain with an `errors` msgid; the
    # form shows them in the host's language like any other form error.
    test "translates a refused group rule into the current locale" do
      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, %{
          name: "Workshop",
          duration_minutes: 60,
          user_id: 1,
          max_participants: 5,
          requires_approval: true
        })

      errors =
        Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
          Helpers.changeset_form_errors(changeset)
        end)

      assert "Gruppenbuchungen können keine Bestätigung erfordern" in errors.max_participants
    end
  end
end
