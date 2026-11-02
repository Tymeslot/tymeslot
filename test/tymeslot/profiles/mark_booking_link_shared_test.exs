defmodule Tymeslot.Profiles.MarkBookingLinkSharedTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles
  @moduletag :database

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo

  setup do
    profile = insert(:profile, user: insert(:user), booking_link_first_shared_at: nil)
    %{profile: profile}
  end

  test "the first share stamps the profile", %{profile: profile} do
    assert {:ok, :shared} = Profiles.mark_booking_link_shared(profile)

    assert %DateTime{} = Repo.reload!(profile).booking_link_first_shared_at
  end

  test "a second share keeps the first timestamp", %{profile: profile} do
    first = ~U[2026-01-01 00:00:00Z]

    Repo.update_all(from(p in ProfileSchema, where: p.id == ^profile.id),
      set: [booking_link_first_shared_at: first]
    )

    # `profile` still carries a nil column, as a long-lived LiveView's would,
    # so this goes through the query rather than the struct short-circuit.
    assert is_nil(profile.booking_link_first_shared_at)
    assert {:ok, :noop} = Profiles.mark_booking_link_shared(profile)

    assert Repo.reload!(profile).booking_link_first_shared_at == first
  end

  test "two concurrent shares stamp once", %{profile: profile} do
    results =
      1..2
      |> Enum.map(fn _attempt ->
        Task.async(fn ->
          Profiles.mark_booking_link_shared(profile)
        end)
      end)
      |> Task.await_many()

    assert Enum.sort(results) == [ok: :noop, ok: :shared]
  end
end
