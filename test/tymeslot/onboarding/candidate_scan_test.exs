defmodule Tymeslot.Onboarding.CandidateScanTest do
  use Tymeslot.DataCase, async: true

  @moduletag :onboarding

  alias Tymeslot.Onboarding

  defp ago(hours), do: DateTime.add(DateTime.utc_now(:second), -hours * 3600, :second)

  defp user_at(inserted_hours_ago, attrs \\ []) do
    user = insert(:user, attrs)

    Repo.update_all(from(u in Tymeslot.Auth.UserSchema, where: u.id == ^user.id),
      set: [inserted_at: ago(inserted_hours_ago)]
    )

    user
  end

  defp ids(rows), do: rows |> Enum.map(& &1.user_id) |> Enum.sort()

  describe "list_candidates_since/2" do
    test "returns accounts that signed up or verified inside the window" do
      recent = user_at(10)
      late_verifier = user_at(400, verified_at: ago(5))
      _old = user_at(400, verified_at: ago(399))

      assert ids(Onboarding.list_candidates_since(ago(48))) ==
               Enum.sort([recent.id, late_verifier.id])
    end

    test "leaves out accounts pending deletion" do
      _leaving = user_at(10, deletion_scheduled_at: DateTime.utc_now(:second))

      assert Onboarding.list_candidates_since(ago(48)) == []
    end

    test "carries the profile facts, and copes with an account that has no profile" do
      published = user_at(10)

      insert(:profile,
        user: published,
        timezone: "Europe/Zurich",
        booking_page_published_at: DateTime.utc_now(:second)
      )

      bare = user_at(10)

      rows = Map.new(Onboarding.list_candidates_since(ago(48)), &{&1.user_id, &1})

      assert %{timezone: "Europe/Zurich", page_published?: true} = rows[published.id]
      assert %{timezone: nil, page_published?: false, verified_at: %DateTime{}} = rows[bare.id]
    end

    test "runs the caller's compose function over the row query" do
      user = user_at(10, email: "composed@example.com")

      compose = fn query -> select_merge(query, [u], %{email: u.email}) end

      assert [%{user_id: id, email: "composed@example.com"}] =
               Onboarding.list_candidates_since(ago(48), compose: compose)

      assert id == user.id
    end
  end

  describe "get_candidate/2" do
    test "returns the row for an account outside any window, with the compose applied" do
      user = user_at(2000)
      compose = fn query -> select_merge(query, [u], %{name: u.name}) end

      assert %{user_id: id, name: name} = Onboarding.get_candidate(user.id, compose: compose)
      assert {id, name} == {user.id, user.name}
    end

    test "returns nil for an unknown account" do
      assert Onboarding.get_candidate(-1) == nil
    end
  end
end
