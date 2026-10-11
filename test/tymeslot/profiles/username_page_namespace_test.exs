defmodule Tymeslot.Profiles.UsernamePageNamespaceTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles

  import Tymeslot.Factory

  alias Tymeslot.Profiles

  test "a page's address is not available as a username" do
    insert(:booking_page, slug: "einfachiso")

    refute Profiles.username_available?("einfachiso")
    refute Profiles.username_available?("EinfachISO")
    assert Profiles.username_status(insert(:profile), "einfachiso") == :taken
  end

  test "an address no page or profile holds is available" do
    assert Profiles.username_available?("nobody-has-this")
  end
end
