defmodule Tymeslot.Migrations.CreateVenuesTest do
  @moduledoc """
  Value-correctness regression for the `create_venues` migration, which
  moves the free-text address of every in-person location into a saved
  venue the location then lists.

  The rows are put into the old shape with raw SQL, because the schema can
  no longer write it, and the migration that ships is then run over them.

  The decisive property is that **no address is lost and none is shared
  across owners**: a booker keeps seeing exactly the address the organiser
  typed, and never another account's.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :meeting_types

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_930_073_021

  defp put_raw_locations(meeting_type, locations) do
    Repo.query!("UPDATE meeting_types SET locations = $2::jsonb[] WHERE id = $1", [
      meeting_type.id,
      locations
    ])
  end

  defp locations(meeting_type) do
    %{rows: [[locations]]} =
      Repo.query!("SELECT locations FROM meeting_types WHERE id = $1", [meeting_type.id])

    locations
  end

  defp venues(user) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id, name, description, position FROM venues WHERE user_id = $1 ORDER BY id",
        [user.id]
      )

    Enum.map(rows, fn [id, name, description, position] ->
      %{id: id, name: name, description: description, position: position}
    end)
  end

  defp meeting_venue_id(meeting) do
    %{rows: [[venue_id, location]]} =
      Repo.query!("SELECT venue_id, location FROM meetings WHERE id = $1", [
        UUID.dump!(meeting.id)
      ])

    {venue_id, location}
  end

  defp in_person(label, details, id \\ "loc-office") do
    %{"id" => id, "kind" => "in_person", "label" => label, "details" => details, "position" => 0}
  end

  test "an in-person address becomes a venue the location lists" do
    user = insert(:user)
    meeting_type = insert(:meeting_type, user: user)
    put_raw_locations(meeting_type, [in_person("Office", "12 High Street")])

    MigrationRunner.rerun!(@version)

    assert [%{id: venue_id, name: "Office", description: "12 High Street"}] = venues(user)
    assert [location] = locations(meeting_type)
    assert location["venue_ids"] == [venue_id]
    assert location["details"] == nil
    assert location["label"] == "Office"
  end

  test "the same label and address on two meeting types share one venue" do
    user = insert(:user)
    first = insert(:meeting_type, user: user)
    second = insert(:meeting_type, user: user)
    put_raw_locations(first, [in_person("Office", "12 High Street")])
    put_raw_locations(second, [in_person("Office", "  12 High Street ")])

    MigrationRunner.rerun!(@version)

    assert [%{id: venue_id}] = venues(user)
    assert [%{"venue_ids" => [^venue_id]}] = locations(first)
    assert [%{"venue_ids" => [^venue_id]}] = locations(second)
  end

  test "the same name with a different address gets a numeric suffix" do
    user = insert(:user)
    first = insert(:meeting_type, user: user)
    second = insert(:meeting_type, user: user)
    put_raw_locations(first, [in_person("Office", "12 High Street")])
    put_raw_locations(second, [in_person("Office", "1 Market Square")])

    MigrationRunner.rerun!(@version)

    assert [
             %{id: high_street, name: "Office", description: "12 High Street"},
             %{id: market_square, name: "Office 2", description: "1 Market Square"}
           ] = venues(user)

    assert [%{"venue_ids" => [^high_street]}] = locations(first)
    assert [%{"venue_ids" => [^market_square]}] = locations(second)
  end

  test "names differing only in case count as the same name" do
    user = insert(:user)
    first = insert(:meeting_type, user: user)
    second = insert(:meeting_type, user: user)
    put_raw_locations(first, [in_person("Office", "12 High Street")])
    put_raw_locations(second, [in_person("office", "1 Market Square")])

    MigrationRunner.rerun!(@version)

    assert [
             %{id: high_street, name: "Office", description: "12 High Street"},
             %{id: market_square, name: "office 2", description: "1 Market Square"}
           ] = venues(user)

    assert [%{"venue_ids" => [^high_street]}] = locations(first)
    assert [%{"venue_ids" => [^market_square]}] = locations(second)
  end

  test "the same address under labels differing only in case shares one venue" do
    user = insert(:user)
    first = insert(:meeting_type, user: user)
    second = insert(:meeting_type, user: user)
    put_raw_locations(first, [in_person("Office", "12 High Street")])
    put_raw_locations(second, [in_person("office", "12 High Street")])

    MigrationRunner.rerun!(@version)

    assert [%{id: venue_id, name: "Office", description: "12 High Street"}] = venues(user)
    assert [%{"venue_ids" => [^venue_id]}] = locations(first)
    assert [%{"venue_ids" => [^venue_id]}] = locations(second)
  end

  # Elixir lowercases "İ" to "i" plus a combining dot, while PostgreSQL's
  # `lower/1` (which the unique index uses) gives a plain "i" under most
  # collations, so the two disagree on whether these names collide. The
  # retry after a skipped insert is only reached on a database whose
  # `lower/1` folds "İ" (C.UTF-8 or another libc UTF-8 locale); elsewhere
  # both names are kept as typed and this test passes without it.
  test "names the database folds together still get distinct venues" do
    user = insert(:user)
    first = insert(:meeting_type, user: user)
    second = insert(:meeting_type, user: user)
    put_raw_locations(first, [in_person("İstanbul", "Istiklal Caddesi 1")])
    put_raw_locations(second, [in_person("istanbul", "Bagdat Caddesi 2")])

    MigrationRunner.rerun!(@version)

    assert [
             %{id: istiklal, description: "Istiklal Caddesi 1"},
             %{id: bagdat, description: "Bagdat Caddesi 2"}
           ] =
             venues(user)

    assert [%{"venue_ids" => [^istiklal]}] = locations(first)
    assert [%{"venue_ids" => [^bagdat]}] = locations(second)
  end

  test "a suffix skips a name the owner already uses as a label" do
    user = insert(:user)
    first = insert(:meeting_type, user: user)
    second = insert(:meeting_type, user: user)
    third = insert(:meeting_type, user: user)
    put_raw_locations(first, [in_person("Office", "12 High Street")])
    put_raw_locations(second, [in_person("Office 2", "Unit 4, Mill Lane")])
    put_raw_locations(third, [in_person("Office", "1 Market Square")])

    MigrationRunner.rerun!(@version)

    assert user |> venues() |> Enum.map(&{&1.name, &1.description}) |> Enum.sort() == [
             {"Office", "12 High Street"},
             {"Office 2", "Unit 4, Mill Lane"},
             {"Office 3", "1 Market Square"}
           ]
  end

  test "a label too long for a venue name is cut to fit, suffix included" do
    user = insert(:user)
    first = insert(:meeting_type, user: user)
    second = insert(:meeting_type, user: user)
    # Each "é" here is two code points, and the column counts code points.
    long = String.duplicate("é", 130)
    put_raw_locations(first, [in_person(long, "12 High Street")])
    put_raw_locations(second, [in_person(long, "1 Market Square")])

    MigrationRunner.rerun!(@version)

    assert [%{name: plain}, %{name: suffixed}] = venues(user)
    assert length(String.codepoints(plain)) == 120
    assert String.starts_with?(long, plain)
    assert length(String.codepoints(suffixed)) == 120
    assert String.ends_with?(suffixed, " 2")
  end

  test "an unnamed location's venue is called In person" do
    user = insert(:user)
    meeting_type = insert(:meeting_type, user: user)
    put_raw_locations(meeting_type, [in_person("  ", "12 High Street")])

    MigrationRunner.rerun!(@version)

    assert [%{name: "In person", description: "12 High Street"}] = venues(user)
  end

  test "numbers each owner's venues in the order their addresses were first seen" do
    user = insert(:user)
    first = insert(:meeting_type, user: user)
    second = insert(:meeting_type, user: user)

    put_raw_locations(first, [
      in_person("Studio", "Canal Street 5", "loc-studio"),
      Map.put(in_person("Office", "12 High Street"), "position", 1)
    ])

    put_raw_locations(second, [in_person("Office", "1 Market Square")])

    MigrationRunner.rerun!(@version)

    assert user |> venues() |> Enum.sort_by(& &1.position) |> Enum.map(&{&1.position, &1.name}) ==
             [{0, "Studio"}, {1, "Office"}, {2, "Office 2"}]
  end

  test "owners never share a venue, even for the same label and address" do
    first_owner = insert(:user)
    second_owner = insert(:user)
    first = insert(:meeting_type, user: first_owner)
    second = insert(:meeting_type, user: second_owner)
    put_raw_locations(first, [in_person("Office", "12 High Street")])
    put_raw_locations(second, [in_person("Office", "12 High Street")])

    MigrationRunner.rerun!(@version)

    assert [%{id: first_venue}] = venues(first_owner)
    assert [%{id: second_venue}] = venues(second_owner)
    assert first_venue != second_venue
    assert [%{"venue_ids" => [^second_venue]}] = locations(second)
  end

  test "an in-person location without an address lists no venue" do
    user = insert(:user)
    meeting_type = insert(:meeting_type, user: user)

    put_raw_locations(meeting_type, [
      in_person("In person", nil, "loc-none"),
      in_person("On site", "   ", "loc-blank")
    ])

    MigrationRunner.rerun!(@version)

    assert venues(user) == []

    assert [
             %{"venue_ids" => [], "details" => nil},
             %{"venue_ids" => [], "details" => nil}
           ] = locations(meeting_type)
  end

  test "other kinds of location are left exactly as they were, in place" do
    user = insert(:user)
    meeting_type = insert(:meeting_type, user: user)

    phone = %{
      "id" => "loc-call",
      "kind" => "phone",
      "label" => "Ring us",
      "details" => "+44 20 7946 0000",
      "position" => 0
    }

    video = %{
      "id" => "loc-video",
      "kind" => "video",
      "label" => "Video call",
      "details" => "Link sent on booking",
      "video_integration_ids" => [7],
      "position" => 2
    }

    office = Map.put(in_person("Office", "12 High Street"), "position", 1)

    # The row is rewritten because of the in-person element, so every other
    # element, malformed ones included, goes through the rewrite too.
    put_raw_locations(meeting_type, [phone, office, video, 42, nil])

    MigrationRunner.rerun!(@version)

    assert [%{id: venue_id}] = venues(user)

    assert [^phone, rewritten_office, ^video, 42, nil] = locations(meeting_type)

    assert rewritten_office ==
             office |> Map.put("venue_ids", [venue_id]) |> Map.put("details", nil)
  end

  test "a row with no in-person location is not touched" do
    user = insert(:user)
    meeting_type = insert(:meeting_type, user: user)

    phone = %{
      "id" => "loc-call",
      "kind" => "phone",
      "label" => "Ring us",
      "details" => "+44 20 7946 0000",
      "position" => 0
    }

    put_raw_locations(meeting_type, [phone])

    MigrationRunner.rerun!(@version)

    assert locations(meeting_type) == [phone]
    assert venues(user) == []
  end

  test "a meeting booked on a location that became a venue records the venue" do
    user = insert(:user)
    meeting_type = insert(:meeting_type, user: user)

    put_raw_locations(meeting_type, [
      in_person("Office", "12 High Street", "loc-office"),
      in_person("In person", nil, "loc-none")
    ])

    at_office =
      insert(:meeting,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        location: "Office (12 High Street)",
        location_kind: "in_person",
        location_option_id: "loc-office"
      )

    later = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

    to_arrange =
      insert(:meeting,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        start_time: later,
        end_time: DateTime.add(later, 60, :minute),
        location: "In person",
        location_kind: "in_person",
        location_option_id: "loc-none"
      )

    MigrationRunner.rerun!(@version)

    assert [%{id: venue_id}] = venues(user)
    assert meeting_venue_id(at_office) == {venue_id, "Office (12 High Street)"}
    assert meeting_venue_id(to_arrange) == {nil, "In person"}
  end

  test "rolling back puts each address back on its location" do
    user = insert(:user)
    meeting_type = insert(:meeting_type, user: user)
    put_raw_locations(meeting_type, [in_person("Office", "12 High Street")])

    MigrationRunner.rerun!(@version)
    MigrationRunner.down!(@version)

    assert [location] = locations(meeting_type)
    assert location["details"] == "12 High Street"
    refute Map.has_key?(location, "venue_ids")
  end
end
