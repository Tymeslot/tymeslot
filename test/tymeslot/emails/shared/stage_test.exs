defmodule Tymeslot.Emails.Shared.StageTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Stage

  describe "stage_band/4" do
    test "includes the title and subtitle in output" do
      html = Stage.stage_band(:confirmed, "Confirmed", "Your meeting is booked", "See you soon")

      assert html =~ "Your meeting is booked"
      assert html =~ "See you soon"
    end

    test "includes the eyebrow in output" do
      html = Stage.stage_band(:confirmed, "Confirmed", "Title")

      assert html =~ "Confirmed"
    end

    test "omits the subtitle block when subtitle is nil" do
      html_with = Stage.stage_band(:confirmed, "Confirmed", "Title", "A subtitle")
      html_without = Stage.stage_band(:confirmed, "Confirmed", "Title", nil)

      assert html_with =~ "A subtitle"
      refute html_without =~ "A subtitle"
    end

    test "escapes special characters in the title" do
      html = Stage.stage_band(:confirmed, "Notice", "A & B")

      assert html =~ "A &amp; B"
      refute html =~ "A &amp;amp; B"
    end
  end
end
