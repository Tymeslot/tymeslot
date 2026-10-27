defmodule TymeslotWeb.Helpers.DeletionDateTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth
  @moduletag :unit

  import Tymeslot.Factory

  alias TymeslotWeb.Helpers.DeletionDate

  test "formats the date in the current locale" do
    user = insert(:user)

    Gettext.put_locale(TymeslotWeb.Gettext, "de")
    assert DeletionDate.format(~U[2026-10-16 10:00:00Z], user) == "16. Oktober 2026"

    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    assert DeletionDate.format(~U[2026-10-16 10:00:00Z], user) == "16 October 2026"
  end
end
