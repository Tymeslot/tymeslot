defmodule Tymeslot.Analytics.SaltQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :queries
  @moduletag :analytics

  alias Tymeslot.Analytics.SaltQueries
  alias Tymeslot.Analytics.SaltSchema

  # Dates no other test module uses, so the uncommitted rows of concurrently
  # running tests never contend for the same key.
  @day ~D[2032-06-15]

  describe "get_or_create/1" do
    test "creates a random 32-byte salt for a day that has none" do
      salt = SaltQueries.get_or_create(@day)

      assert byte_size(salt) == 32
      assert Repo.get!(SaltSchema, @day).salt == salt
    end

    test "returns the stored salt for a day that already has one" do
      existing = :crypto.strong_rand_bytes(32)
      Repo.insert!(%SaltSchema{date: @day, salt: existing})

      assert SaltQueries.get_or_create(@day) == existing
    end

    test "gives concurrent first callers the same salt" do
      salts =
        1..2
        |> Enum.map(fn _caller -> Task.async(fn -> SaltQueries.get_or_create(@day) end) end)
        |> Task.await_many()

      assert [salt, salt] = salts
      assert Repo.aggregate(SaltSchema, :count) == 1
    end

    test "gives each day its own salt" do
      refute SaltQueries.get_or_create(@day) ==
               SaltQueries.get_or_create(Date.add(@day, 1))
    end
  end

  describe "delete_before/1" do
    test "deletes the salts of earlier days only" do
      for date <- [Date.add(@day, -2), Date.add(@day, -1), @day, Date.add(@day, 1)] do
        SaltQueries.get_or_create(date)
      end

      assert {2, nil} = SaltQueries.delete_before(@day)

      assert Repo.all(from(s in SaltSchema, select: s.date, order_by: s.date)) ==
               [@day, Date.add(@day, 1)]
    end
  end
end
