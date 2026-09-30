defmodule Tymeslot.Repo.Migrations.CreateVenues do
  @moduledoc """
  Saved venues: the places an organiser meets people, kept once per account
  and referenced by id from the in-person locations of their meeting types.

  `position` is the organiser's own order for their venues, set by drag and
  drop on the Locations page and used wherever venues are listed.

  `meetings.venue_id` pins which venue a booking was made at, so a reschedule
  can open on it. It is nullable and nilified when the venue goes: the
  meeting's `location` text is the record of where it was booked.

  `meetings.address_to_arrange` records that an in-person booking was made
  on a location offering no venue, so its address is arranged afterwards.
  It is stated rather than read off a nil `venue_id`, which a deleted venue
  also leaves.

  Until now an in-person location carried its address as free text in its
  `details`, retyped on every meeting type. This migration moves every
  address into a venue:

    * each in-person location with a non-blank address becomes a venue owned
      by the meeting type's owner, named after the location's label, with the
      address as its description;
    * locations with the same owner, label (ignoring case) and address share
      one venue, named with the label's casing as first seen;
    * each owner's venues are numbered (`position`) in the order their
      addresses were first seen: oldest meeting type first, then its
      locations in their stored order;
    * when one owner ends up with two different venues of the same name
      (ignoring case, as the unique index does), the later ones get the
      lowest free numeric suffix ("Office 2"), because a booker must never be
      offered two identical choices; plain names are handed out first, so an
      owner's own "Office 2" label keeps its name;
    * the location then lists that venue in `venue_ids` and its `details` is
      cleared. In-person locations without an address get an empty list and
      keep meaning "the address is arranged after booking";
    * meetings booked on a location that became a venue record it in
      `venue_id`, so a reschedule opens on it. Their `location` text is
      never rewritten;
    * in-person meetings booked on a location left listing no venue (it
      had no address) get `address_to_arrange`, which is what they were.
      Every other existing meeting keeps `false`.

  Rolling back writes each location's first venue's description back into
  `details` before the table is dropped.

  The data steps are plain SQL driven from Elixir rather than the schemas,
  so the migration keeps meaning what it means today whatever the schemas
  become.
  """
  use Ecto.Migration

  # The table is created empty in this migration, so its unique index and its
  # reference to users cannot lock or rewrite anything. `meetings.venue_id` is
  # a new nullable column with no default; Tymeslot deploys as a single
  # instance and migrates with the app stopped, so the brief lock while its
  # foreign key and index are added is acceptable. The raw SQL is the backfill
  # and its rollback; the column and table removals are confined to `down/0`.
  # `position`'s default is part of CREATE TABLE, so it rewrites no rows.
  # `meetings.address_to_arrange` has a constant default, which PostgreSQL
  # 11 and later store in the catalogue without rewriting the table.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file column_removed
  # excellent_migrations:safety-assured-for-this-file table_dropped

  @name_max_length 120
  @fallback_name "In person"
  @insert_batch 500

  def up do
    create table(:venues) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:name, :string, size: @name_max_length, null: false)
      add(:description, :text)
      add(:position, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime)
    end

    # Names are unique per owner regardless of case, so "Studio" and
    # "studio" cannot both appear in the owner's picker.
    create(unique_index(:venues, [:user_id, "lower(name)"], name: :venues_user_id_lower_name_index))

    alter table(:meetings) do
      add(:venue_id, references(:venues, on_delete: :nilify_all))
      add(:address_to_arrange, :boolean, null: false, default: false)
    end

    create(index(:meetings, [:venue_id]))

    execute(fn -> backfill() end)
  end

  def down do
    execute(fn -> restore_details() end)

    alter table(:meetings) do
      remove(:address_to_arrange)
      remove(:venue_id)
    end

    drop(table(:venues))
  end

  defp backfill do
    rows = load_in_person_rows()
    addresses = addresses(rows)
    venue_ids = addresses |> name_venues() |> insert_venues(positions(addresses))

    Enum.each(rows, &rewrite_locations(&1, venue_ids))
    link_meetings()
    mark_addresses_to_arrange()
  end

  # Meeting types with an in-person location, oldest first, so an owner's
  # plain venue name goes to the address they set up first.
  defp load_in_person_rows do
    %{rows: rows} =
      repo().query!("""
      SELECT id, user_id, locations
      FROM meeting_types
      WHERE user_id IS NOT NULL
        AND EXISTS (SELECT 1 FROM unnest(locations) AS loc WHERE loc ->> 'kind' = 'in_person')
      ORDER BY id
      """)

    Enum.map(rows, fn [id, user_id, locations] ->
      %{id: id, user_id: user_id, locations: locations || []}
    end)
  end

  # One `{key, label}` per venue to create, in the order the addresses were
  # first seen. The key is `{owner, lowercased label, address}`, so labels
  # differing only in case share a venue; the label is the casing first seen,
  # which becomes the venue's name.
  defp addresses(rows) do
    rows
    |> Enum.flat_map(fn row -> Enum.flat_map(row.locations, &address(row.user_id, &1)) end)
    |> Enum.uniq_by(fn {key, _label} -> key end)
  end

  defp address(user_id, %{"kind" => "in_person"} = location) do
    case address_key(user_id, location) do
      {_user_id, _folded, ""} -> []
      key -> [{key, label(location)}]
    end
  end

  defp address(_user_id, _location), do: []

  defp address_key(user_id, location) do
    {user_id, String.downcase(label(location)), trimmed(location["details"])}
  end

  defp label(location) do
    case trimmed(location["label"]) do
      "" -> @fallback_name
      label -> truncate(label, @name_max_length)
    end
  end

  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(_value), do: ""

  # The column counts code points, not graphemes, so a label full of
  # combining characters must be cut by code point to fit.
  defp truncate(string, max_length) do
    string |> String.codepoints() |> Enum.take(max_length) |> Enum.join()
  end

  # `{key, label, name}` for every address. Within one owner, the first
  # address with a given label keeps the label itself; every later one with
  # that label gets the lowest free numeric suffix. Labels are compared
  # ignoring case, as the unique index compares names.
  defp name_venues(addresses) do
    addresses
    |> Enum.group_by(fn {{user_id, _folded, _address}, _label} -> user_id end)
    |> Enum.flat_map(fn {_user_id, owner_addresses} -> name_owner_addresses(owner_addresses) end)
  end

  defp name_owner_addresses(addresses) do
    {firsts, rest} = split_first_per_label(addresses)
    taken = MapSet.new(firsts, fn {{_user_id, folded, _address}, _label} -> folded end)

    {suffixed, _taken} =
      Enum.map_reduce(rest, taken, fn {key, label}, taken ->
        name = free_name(label, 2, taken)
        {{key, label, name}, MapSet.put(taken, String.downcase(name))}
      end)

    Enum.map(firsts, fn {key, label} -> {key, label, label} end) ++ suffixed
  end

  defp split_first_per_label(addresses) do
    {firsts, rest, _seen} = Enum.reduce(addresses, {[], [], MapSet.new()}, &split_address/2)
    {Enum.reverse(firsts), Enum.reverse(rest)}
  end

  defp split_address({{_user_id, folded, _address}, _label} = entry, {firsts, rest, seen}) do
    if MapSet.member?(seen, folded),
      do: {firsts, [entry | rest], seen},
      else: {[entry | firsts], rest, MapSet.put(seen, folded)}
  end

  defp free_name(label, n, taken) do
    name = suffixed(label, n)

    if MapSet.member?(taken, String.downcase(name)),
      do: free_name(label, n + 1, taken),
      else: name
  end

  defp suffixed(label, n) do
    suffix = " #{n}"
    truncate(label, @name_max_length - String.length(suffix)) <> suffix
  end

  # `%{key => position}`: each owner's addresses numbered from 0 in the order
  # `addresses/1` saw them, which is deterministic because the rows are read
  # by meeting type id and each row's locations in stored order.
  defp positions(addresses) do
    addresses
    |> Enum.map(fn {key, _label} -> key end)
    |> Enum.group_by(fn {user_id, _folded, _address} -> user_id end)
    |> Enum.flat_map(fn {_user_id, owner_keys} -> Enum.with_index(owner_keys) end)
    |> Map.new()
  end

  # `{key, label, name}` triples in, `%{key => venue_id}` out.
  defp insert_venues(named, positions) do
    named
    |> Enum.chunk_every(@insert_batch)
    |> Enum.flat_map(&insert_batch(&1, positions))
    |> Map.new()
  end

  # `String.downcase/1` and the database's `lower/1` do not always agree
  # ("İ" is one example), so a name the naming above thought free can still
  # collide with another under the unique index. Such a row is skipped here
  # rather than failing the whole migration, and placed under the next
  # suffix the database accepts.
  defp insert_batch(named, positions) do
    user_ids = Enum.map(named, fn {{user_id, _folded, _address}, _label, _name} -> user_id end)
    names = Enum.map(named, fn {_key, _label, name} -> name end)
    addresses = Enum.map(named, fn {{_user_id, _folded, address}, _label, _name} -> address end)
    orders = Enum.map(named, fn {key, _label, _name} -> Map.fetch!(positions, key) end)

    %{rows: rows} =
      repo().query!(
        """
        INSERT INTO venues (user_id, name, description, position, inserted_at, updated_at)
        SELECT v.user_id, v.name, v.description, v.position,
               date_trunc('second', now() AT TIME ZONE 'utc'),
               date_trunc('second', now() AT TIME ZONE 'utc')
        FROM unnest($1::bigint[], $2::text[], $3::text[], $4::integer[])
          AS v(user_id, name, description, position)
        ON CONFLICT DO NOTHING
        RETURNING id, user_id, name
        """,
        [user_ids, names, addresses, orders]
      )

    ids = Map.new(rows, fn [id, user_id, name] -> {{user_id, name}, id} end)

    Enum.map(named, fn {{user_id, _folded, _address} = key, label, name} ->
      case Map.fetch(ids, {user_id, name}) do
        {:ok, id} -> {key, id}
        :error -> {key, insert_suffixed(key, label, 2, Map.fetch!(positions, key))}
      end
    end)
  end

  defp insert_suffixed({user_id, _folded, address} = key, label, n, position) do
    %{rows: rows} =
      repo().query!(
        """
        INSERT INTO venues (user_id, name, description, position, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4,
                date_trunc('second', now() AT TIME ZONE 'utc'),
                date_trunc('second', now() AT TIME ZONE 'utc'))
        ON CONFLICT DO NOTHING
        RETURNING id
        """,
        [user_id, suffixed(label, n), address, position]
      )

    case rows do
      [[id]] -> id
      [] -> insert_suffixed(key, label, n + 1, position)
    end
  end

  defp rewrite_locations(%{id: id, user_id: user_id, locations: locations}, venue_ids) do
    rewritten = Enum.map(locations, &rewrite_location(&1, user_id, venue_ids))

    if rewritten != locations do
      repo().query!("UPDATE meeting_types SET locations = $2::jsonb[] WHERE id = $1", [
        id,
        rewritten
      ])
    end
  end

  defp rewrite_location(%{"kind" => "in_person"} = location, user_id, venue_ids) do
    ids =
      case Map.fetch(venue_ids, address_key(user_id, location)) do
        {:ok, venue_id} -> [venue_id]
        :error -> []
      end

    location
    |> Map.put("venue_ids", ids)
    |> Map.put("details", nil)
  end

  defp rewrite_location(location, _user_id, _venue_ids), do: location

  defp link_meetings do
    repo().query!("""
    UPDATE meetings AS m
    SET venue_id = (loc -> 'venue_ids' ->> 0)::bigint
    FROM meeting_types AS mt
    CROSS JOIN LATERAL unnest(mt.locations) AS loc
    WHERE m.meeting_type_id = mt.id
      AND m.venue_id IS NULL
      AND m.location_kind = 'in_person'
      AND m.location_option_id = loc ->> 'id'
      AND loc ->> 'kind' = 'in_person'
      AND jsonb_typeof(loc -> 'venue_ids') = 'array'
      AND (loc -> 'venue_ids' ->> 0) IS NOT NULL
    """)
  end

  # Only a location the backfill rewrote carries `venue_ids`, and an empty
  # list there is exactly an in-person location without an address.
  defp mark_addresses_to_arrange do
    repo().query!("""
    UPDATE meetings AS m
    SET address_to_arrange = true
    FROM meeting_types AS mt
    CROSS JOIN LATERAL unnest(mt.locations) AS loc
    WHERE m.meeting_type_id = mt.id
      AND m.location_kind = 'in_person'
      AND m.location_option_id = loc ->> 'id'
      AND loc ->> 'kind' = 'in_person'
      AND loc -> 'venue_ids' = '[]'::jsonb
    """)
  end

  defp restore_details do
    %{rows: venue_rows} = repo().query!("SELECT id, description FROM venues")
    descriptions = Map.new(venue_rows, fn [id, description] -> {id, description} end)

    %{rows: rows} =
      repo().query!("""
      SELECT id, locations
      FROM meeting_types
      WHERE EXISTS (SELECT 1 FROM unnest(locations) AS loc WHERE loc ? 'venue_ids')
      """)

    Enum.each(rows, fn [id, locations] ->
      restored = Enum.map(locations, &restore_location(&1, descriptions))

      repo().query!("UPDATE meeting_types SET locations = $2::jsonb[] WHERE id = $1", [
        id,
        restored
      ])
    end)
  end

  defp restore_location(%{"venue_ids" => ids} = location, descriptions) do
    details =
      case ids do
        [first | _rest] -> Map.get(descriptions, first, location["details"])
        _none -> location["details"]
      end

    location
    |> Map.delete("venue_ids")
    |> Map.put("details", details)
  end

  defp restore_location(location, _descriptions), do: location
end
