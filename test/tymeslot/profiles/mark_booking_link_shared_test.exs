defmodule Tymeslot.Profiles.MarkBookingLinkSharedTest do
  use Tymeslot.DataCase, async: false

  @moduletag :profiles
  @moduletag :database

  alias Ecto.Adapters.SQL.Sandbox
  alias Tymeslot.Profiles
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
    assert {:ok, :shared} = Profiles.mark_booking_link_shared(profile)
    first = Repo.reload!(profile)

    # A stale struct (as a long-lived LiveView would hold) still cannot restamp.
    later = DateTime.add(DateTime.utc_now(:second), 3600)
    assert {:ok, :noop} = Profiles.mark_booking_link_shared(profile)
    assert {:ok, :noop} = Profiles.mark_booking_link_shared(first)

    stamped = Repo.reload!(profile).booking_link_first_shared_at
    assert stamped == first.booking_link_first_shared_at
    assert DateTime.compare(stamped, later) == :lt
  end

  test "two concurrent shares stamp once", %{profile: profile} do
    parent = self()

    results =
      1..2
      |> Enum.map(fn _attempt ->
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          Profiles.mark_booking_link_shared(profile)
        end)
      end)
      |> Task.await_many()

    assert Enum.sort(results) == [ok: :noop, ok: :shared]
  end
end
