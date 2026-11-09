defmodule TymeslotWeb.Dashboard.BookingsManagement.GuestActionsTest do
  use ExUnit.Case, async: true

  @moduletag :meetings

  alias TymeslotWeb.Dashboard.BookingsManagement.GuestActions

  defp emails(raw), do: raw |> GuestActions.parse_guests() |> Enum.map(& &1.email)

  describe "parse_guests/1" do
    test "accepts the separators a person reaches for when listing colleagues" do
      assert emails("a@example.com, b@example.com; c@example.com") ==
               ~w(a@example.com b@example.com c@example.com)

      assert emails("a@example.com\nb@example.com\r\nc@example.com") ==
               ~w(a@example.com b@example.com c@example.com)

      assert emails("a@example.com b@example.com") == ~w(a@example.com b@example.com)
    end

    test "reads the name typed with an address, spaces and quoted commas included" do
      assert GuestActions.parse_guests(
               ~s(Grace Hopper <grace@example.com>, "Lovelace, Ada" <ada@example.com>)
             ) ==
               [
                 %{email: "grace@example.com", name: "Grace Hopper"},
                 %{email: "ada@example.com", name: "Lovelace, Ada"}
               ]
    end

    test "ignores stray whitespace and empty stretches between addresses" do
      assert emails("  a@example.com ,,  \n\n b@example.com  \t") ==
               ~w(a@example.com b@example.com)
    end

    test "returns nothing for an empty field" do
      assert GuestActions.parse_guests("") == []
      assert GuestActions.parse_guests("   \n ") == []
      assert GuestActions.parse_guests(nil) == []
    end

    # Validity is `Meetings.Guests`' business; splitting is this function's.
    test "passes unusable entries along rather than judging them" do
      assert emails("not-an-email, ok@example.com") == ["not-an-email", "ok@example.com"]
    end
  end
end
