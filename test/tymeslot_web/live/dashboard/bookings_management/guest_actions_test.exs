defmodule TymeslotWeb.Dashboard.BookingsManagement.GuestActionsTest do
  use ExUnit.Case, async: true

  @moduletag :meetings

  alias TymeslotWeb.Dashboard.BookingsManagement.GuestActions

  describe "parse_emails/1" do
    test "accepts the separators a person reaches for when listing colleagues" do
      assert GuestActions.parse_emails("a@example.com, b@example.com; c@example.com") ==
               ~w(a@example.com b@example.com c@example.com)

      assert GuestActions.parse_emails("a@example.com\nb@example.com\r\nc@example.com") ==
               ~w(a@example.com b@example.com c@example.com)

      assert GuestActions.parse_emails("a@example.com b@example.com") ==
               ~w(a@example.com b@example.com)
    end

    test "ignores stray whitespace and empty stretches between addresses" do
      assert GuestActions.parse_emails("  a@example.com ,,  \n\n b@example.com  \t") ==
               ~w(a@example.com b@example.com)
    end

    test "returns nothing for an empty field" do
      assert GuestActions.parse_emails("") == []
      assert GuestActions.parse_emails("   \n ") == []
      assert GuestActions.parse_emails(nil) == []
    end

    # Validity is `Meetings.Guests`' business; splitting is this function's.
    test "passes unusable entries along rather than judging them" do
      assert GuestActions.parse_emails("not-an-email, ok@example.com") ==
               ["not-an-email", "ok@example.com"]
    end
  end
end
