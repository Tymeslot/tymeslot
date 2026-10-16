defmodule TymeslotWeb.Themes.Shared.BookingLabelsTest do
  @moduledoc """
  The submit button names what pressing it does: a request on a gated
  meeting type, a reschedule when rescheduling, otherwise the theme's own
  label, in the theme's voice where it has one.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.Themes.Shared.BookingLabels

  @gated %{requires_approval: true}
  @open %{requires_approval: false}

  describe "submit_label/4" do
    test "names a request on a gated meeting type, and a new time when rescheduling one" do
      assert BookingLabels.submit_label(false, @gated, "Book") == "Request meeting"
      assert BookingLabels.submit_label(true, @gated, "Book") == "Request new time"
    end

    test "names a reschedule on an open meeting type" do
      assert BookingLabels.submit_label(true, @open, "Book") == "Reschedule Meeting"
    end

    test "is the theme's own label for an ordinary booking" do
      assert BookingLabels.submit_label(false, @open, "Book") == "Book"
      assert BookingLabels.submit_label(false, nil, "Book") == "Book"
    end

    test "is the theme's voice for an ordinary booking where it words one" do
      assert BookingLabels.submit_label(false, @open, "Book", :fixture) == "Book it"
      assert BookingLabels.submit_label(false, @open, "Book", :showcase) == "Book"
    end

    test "keeps the request labels the voice does not word" do
      assert BookingLabels.submit_label(false, @gated, "Book", :fixture) == "Request meeting"
    end
  end
end
